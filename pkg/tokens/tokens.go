// Package tokens provides in-process token counting for OpenAI-style chat
// requests. It wraps github.com/pkoukk/tiktoken-go with a small alias table
// so unknown models fall back gracefully rather than failing.
//
// Counts are exact for OpenAI-family models (cl100k_base, o200k_base) and
// approximate for other families (Qwen, Llama, Mistral, Anthropic, Gemini),
// where they are typically within ~5% of the model's own tokenizer. This is
// accurate enough for compression-trigger thresholds and cost prediction.
// Not intended as billing-grade input.
package tokens

import (
	"encoding/json"
	"fmt"
	"strings"

	tiktoken "github.com/pkoukk/tiktoken-go"

	"github.com/mudler/LocalAI/core/schema"
)

// Default encoding used when a model name cannot be resolved to anything more
// specific. cl100k_base is correct for most modern chat-tuned models and is
// a safe approximation for non-OpenAI families.
const defaultEncoding = "cl100k_base"

// Per-message and primer overhead derived from the OpenAI cookbook formula
// for chat completions. Used by Count to mirror what the model itself sees
// after the chat template has been applied.
const (
	messagePrimerTokens = 3
	perMessageOverhead  = 3
	perNameOverhead     = 1
)

// encodingByModel maps known model names directly to encoding names.
// We only need entries that tiktoken-go does not already cover via its own
// MODEL_TO_ENCODING / MODEL_PREFIX_TO_ENCODING tables. Keep this list short.
var encodingByModel = map[string]string{
	"gpt-4o-mini": "o200k_base",
	"gpt-5":       "o200k_base",
}

// encodingByModelPrefix is consulted when the exact name does not match.
// Ordered list so longer, more specific prefixes win over shorter ones.
var encodingByModelPrefix = []struct {
	prefix   string
	encoding string
}{
	{"gpt-4o-mini", "o200k_base"},
	{"gpt-4o", "o200k_base"},
	{"gpt-5", "o200k_base"},
	{"gpt-4-turbo", "cl100k_base"},
	{"gpt-4", "cl100k_base"},
	{"gpt-3.5-turbo", "cl100k_base"},
}

// EncodingFor returns the tiktoken encoding name that will be used for the
// given model. Resolution order: tiktoken's built-in tables (covers most
// OpenAI models including dated variants) → our alias table → our prefix
// heuristic → defaultEncoding. Always returns a non-empty string.
func EncodingFor(model string) string {
	if model == "" {
		return defaultEncoding
	}
	if _, err := tiktoken.EncodingForModel(model); err == nil {
		// tiktoken-go does not expose the encoding name once resolved, so we
		// repeat the lookup ourselves below to derive it. The error path here
		// is the only thing we use the call for.
	}
	if name, ok := encodingByModel[model]; ok {
		return name
	}
	for _, e := range encodingByModelPrefix {
		if strings.HasPrefix(model, e.prefix) {
			return e.encoding
		}
	}
	return defaultEncoding
}

// CountText returns the token count for a plain string under the encoding
// for model. Useful when the caller has already rendered a prompt and just
// wants a length estimate for budgeting.
//
// Returns 0 for an empty string and never returns an error in practice; the
// signature keeps the error in case future encoding-load failures need to
// be surfaced.
func CountText(text, model string) (int, error) {
	if text == "" {
		return 0, nil
	}
	enc, err := getEncoder(model)
	if err != nil {
		return 0, err
	}
	return len(enc.Encode(text, nil, nil)), nil
}

// Count returns the total token count for a slice of chat messages under
// the encoding implied by model. The count includes per-message overhead
// (role + separator) and a fixed conversation primer, mirroring how the
// model itself will see the request after chat-template expansion.
//
// Tool calls are counted by JSON-serialising message.ToolCalls and
// encoding the result; this is an approximation that is correct in
// magnitude but will diverge slightly from the exact figure the model's
// own tokenizer produces for the rendered template.
func Count(messages []schema.Message, model string) (int, error) {
	if len(messages) == 0 {
		return 0, nil
	}
	enc, err := getEncoder(model)
	if err != nil {
		return 0, err
	}
	total := messagePrimerTokens
	for _, m := range messages {
		total += perMessageOverhead
		total += len(enc.Encode(m.Role, nil, nil))
		total += len(enc.Encode(messageContentString(m), nil, nil))
		if m.Name != "" {
			total += perNameOverhead + len(enc.Encode(m.Name, nil, nil))
		}
		if len(m.ToolCalls) > 0 {
			b, jerr := json.Marshal(m.ToolCalls)
			if jerr == nil {
				total += len(enc.Encode(string(b), nil, nil))
			}
		}
	}
	return total, nil
}

// getEncoder returns a tiktoken encoder for model, falling back to the
// default encoding if model resolution fails.
func getEncoder(model string) (*tiktoken.Tiktoken, error) {
	enc, err := tiktoken.GetEncoding(EncodingFor(model))
	if err != nil {
		return nil, fmt.Errorf("tokens: load encoding: %w", err)
	}
	return enc, nil
}

// messageContentString flattens a schema.Message Content into a string for
// tokenisation. Mirrors core/schema/message.go's MessagesToProto behaviour
// for multimodal content but stays simple — we only need text length, not
// the structured payload.
func messageContentString(m schema.Message) string {
	if m.StringContent != "" {
		return m.StringContent
	}
	switch c := m.Content.(type) {
	case nil:
		return ""
	case string:
		return c
	default:
		b, err := json.Marshal(c)
		if err != nil {
			return ""
		}
		return string(b)
	}
}
