// Package compress implements server-side context compression for chat
// completions. It is the algorithmic core used by the compression middleware
// in core/http/middleware/compression.go and is intentionally decoupled from
// the HTTP layer — callers provide a Summarizer interface to invoke the
// compressor model so this package stays unit-testable in isolation.
//
// The pipeline:
//
//  1. count tokens for the request via pkg/tokens
//  2. if under context_size * trigger_at_ratio, return unchanged
//  3. partition messages into a head (to compress) and a tail (to keep)
//     such that the tail covers at least keep_tail_tokens
//  4. ask the Summarizer to produce a single summary of the head
//  5. replace the head with one system message [COMPRESSED: <summary>]
//  6. if the resulting request is still over context_size, drop the oldest
//     summary and retry — until either it fits or the configured overflow
//     strategy says "error"
//
// The package exposes one entrypoint (Compress) and one interface
// (Summarizer). Everything else is private detail.
package compress

import (
	"context"
	"errors"
	"fmt"

	"github.com/mudler/LocalAI/core/schema"
	"github.com/mudler/LocalAI/pkg/tokens"
)

// CompressedTurnRolePrefix is the marker prepended to summary content so
// downstream tools (logging, future bulk-retrieval) can identify
// compression-injected messages.
const CompressedTurnPrefix = "[COMPRESSED]: "

// CompressedTurnRole is the role assigned to the synthetic summary message.
// "system" is the OpenAI-spec choice; downstream reasoning/tool layers
// generally treat system messages as guidance rather than turn content,
// which is what we want here.
const CompressedTurnRole = "system"

// OverflowDropOldestSummary tells Compress to drop the oldest synthetic
// summary message and try again when the post-compression request still
// exceeds context_size. This is the default (per RFC #9534).
const OverflowDropOldestSummary = "drop_oldest_summary"

// OverflowError tells Compress to return an OverflowError instead of
// recovering. Useful when an operator prefers loud failures.
const OverflowError = "error"

// MaxOverflowRecoveries bounds the recovery loop so a pathologically large
// trailing tail cannot pin Compress in an endless retry. Two recoveries
// in a row covers all cases observed in walcz.de production.
const MaxOverflowRecoveries = 2

// ErrOverflow is returned when on_post_compression_overflow is "error" and
// the compressed request still exceeds context_size, or when
// drop_oldest_summary has exhausted MaxOverflowRecoveries.
var ErrOverflow = errors.New("compress: request still exceeds context_size after compression")

// Summarizer produces a single-paragraph summary of the messages it is
// given. Implementations typically wrap a model-backend call; the test
// suite uses a stub. Errors are surfaced to the caller, which decides
// whether to fail the request or fall back to passthrough.
type Summarizer interface {
	Summarize(ctx context.Context, model string, messages []schema.Message, maxTokens int) (string, error)
}

// Config holds everything Compress needs at runtime. Mirrors
// core/config/CompressionConfig but stays in this package so pkg/compress
// has no upward dependency on core/config (avoids import cycles).
type Config struct {
	// ContextSize is the model's context window in tokens.
	// Required; <=0 disables compression for this call.
	ContextSize int

	// TriggerAtRatio is the share of ContextSize at which compression fires.
	// Compress treats values <= 0 or > 1 as "disabled" without erroring.
	TriggerAtRatio float64

	// KeepTailTokens is the minimum number of trailing tokens preserved.
	KeepTailTokens int

	// MaxSummaryTokens caps the summary's length.
	MaxSummaryTokens int

	// CompressorModel is the model name passed to Summarizer.Summarize.
	// When empty, the caller's primary model is used.
	CompressorModel string

	// PrimaryModel is what the request will ultimately be served by; used
	// for token counting (encoding lookup) and as a fallback when
	// CompressorModel is empty.
	PrimaryModel string

	// OnPostCompressionOverflow is one of OverflowDropOldestSummary
	// (default) or OverflowError.
	OnPostCompressionOverflow string
}

// Result reports what Compress did for one request.
type Result struct {
	// Messages is the (possibly modified) message list to forward to the
	// primary model.
	Messages []schema.Message

	// Skipped is true when no compression was attempted (under threshold,
	// disabled, or short-circuit).
	Skipped bool

	// SkipReason is set when Skipped is true. Free-form, suitable for logs.
	SkipReason string

	// OriginalTokens is the request size before compression.
	OriginalTokens int

	// CompressedTokens is the request size after compression. Equal to
	// OriginalTokens when Skipped.
	CompressedTokens int

	// DroppedTurns is how many original messages were folded into the
	// summary. Zero when Skipped.
	DroppedTurns int

	// SummaryTokens is the size of the synthetic summary message.
	SummaryTokens int

	// Compressor is the model used to produce the summary.
	Compressor string

	// OverflowRecoveries counts how many times we had to drop a synthetic
	// summary because the request still exceeded context_size.
	OverflowRecoveries int
}

// Compress applies the policy in cfg to messages and returns the resulting
// message list plus metadata. It never panics; any failure during
// summarisation is returned as an error and the caller decides whether to
// fall through to passthrough.
//
// When compression is skipped (under threshold, disabled, or empty input)
// the returned Messages is the same slice the caller passed in.
func Compress(
	ctx context.Context,
	messages []schema.Message,
	cfg Config,
	sum Summarizer,
) (Result, error) {
	if len(messages) == 0 {
		return Result{Messages: messages, Skipped: true, SkipReason: "no messages"}, nil
	}
	if cfg.ContextSize <= 0 || cfg.TriggerAtRatio <= 0 || cfg.TriggerAtRatio > 1 {
		return Result{
			Messages:   messages,
			Skipped:    true,
			SkipReason: "trigger disabled by config",
		}, nil
	}
	if cfg.KeepTailTokens < 0 {
		return Result{}, fmt.Errorf("compress: keep_tail_tokens must be >= 0, got %d", cfg.KeepTailTokens)
	}

	encodingModel := cfg.PrimaryModel
	original, err := tokens.Count(messages, encodingModel)
	if err != nil {
		return Result{}, fmt.Errorf("compress: count original tokens: %w", err)
	}
	threshold := int(float64(cfg.ContextSize) * cfg.TriggerAtRatio)
	if original < threshold {
		return Result{
			Messages:         messages,
			Skipped:          true,
			SkipReason:       "under trigger threshold",
			OriginalTokens:   original,
			CompressedTokens: original,
		}, nil
	}

	compressorModel := cfg.CompressorModel
	if compressorModel == "" {
		compressorModel = cfg.PrimaryModel
	}

	head, tail, err := partition(messages, cfg.KeepTailTokens, encodingModel)
	if err != nil {
		return Result{}, err
	}
	if len(head) == 0 {
		// Tail already covers >= KeepTailTokens, nothing to compress.
		return Result{
			Messages:         messages,
			Skipped:          true,
			SkipReason:       "tail already preserves more than keep_tail_tokens",
			OriginalTokens:   original,
			CompressedTokens: original,
		}, nil
	}

	summary, err := sum.Summarize(ctx, compressorModel, head, cfg.MaxSummaryTokens)
	if err != nil {
		return Result{}, fmt.Errorf("compress: summarize: %w", err)
	}
	summaryTokens, err := tokens.CountText(summary, encodingModel)
	if err != nil {
		return Result{}, fmt.Errorf("compress: count summary tokens: %w", err)
	}

	out := buildCompressed(summary, tail)

	compressed, err := tokens.Count(out, encodingModel)
	if err != nil {
		return Result{}, fmt.Errorf("compress: count compressed tokens: %w", err)
	}

	res := Result{
		Messages:         out,
		OriginalTokens:   original,
		CompressedTokens: compressed,
		DroppedTurns:     len(head),
		SummaryTokens:    summaryTokens,
		Compressor:       compressorModel,
	}

	if compressed <= cfg.ContextSize {
		return res, nil
	}

	// Overflow recovery: still over context. Repeatedly drop the oldest
	// synthetic summary message until either the request fits or we hit
	// MaxOverflowRecoveries.
	overflow := cfg.OnPostCompressionOverflow
	if overflow == "" {
		overflow = OverflowDropOldestSummary
	}
	if overflow == OverflowError {
		return res, ErrOverflow
	}

	for i := 0; i < MaxOverflowRecoveries; i++ {
		out = dropOldestSummary(out)
		if len(out) == 0 {
			return res, ErrOverflow
		}
		compressed, err = tokens.Count(out, encodingModel)
		if err != nil {
			return Result{}, fmt.Errorf("compress: count after recovery: %w", err)
		}
		res.Messages = out
		res.CompressedTokens = compressed
		res.OverflowRecoveries = i + 1
		if compressed <= cfg.ContextSize {
			return res, nil
		}
	}
	return res, ErrOverflow
}

// buildCompressed produces the final message list: one synthetic system
// summary followed by the preserved tail.
func buildCompressed(summary string, tail []schema.Message) []schema.Message {
	out := make([]schema.Message, 0, 1+len(tail))
	out = append(out, schema.Message{
		Role:    CompressedTurnRole,
		Content: CompressedTurnPrefix + summary,
	})
	out = append(out, tail...)
	return out
}

// dropOldestSummary removes the first message if it is a synthetic
// compression summary. Returns the input unchanged when no synthetic
// summary is present (defensive — caller logic should prevent this).
func dropOldestSummary(messages []schema.Message) []schema.Message {
	if len(messages) == 0 {
		return messages
	}
	first := messages[0]
	if first.Role != CompressedTurnRole {
		return messages
	}
	content, ok := first.Content.(string)
	if !ok || !startsWith(content, CompressedTurnPrefix) {
		return messages
	}
	return messages[1:]
}

// startsWith is a tiny inlined helper to avoid pulling strings into this
// file when the only use is a constant prefix check.
func startsWith(s, prefix string) bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}
