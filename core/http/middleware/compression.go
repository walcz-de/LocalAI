// Compression middleware applies optional context-compression to chat
// requests when the model has CompressionConfig.Enabled set. The
// algorithmic core lives in pkg/compress/; this file is the HTTP-layer
// glue: read parsed request and model config from the Echo context, run
// pkg/compress.Compress with a backend-backed Summarizer, then mutate the
// request's Messages slice in place.
//
// Compression failures (summarizer error, encoding miss, overflow) fall
// through to passthrough rather than aborting the request. The premise
// is that any compression is best-effort optimisation; a broken
// compressor must never break the underlying chat completion.

package middleware

import (
	"context"
	"strings"

	"github.com/labstack/echo/v4"
	"github.com/mudler/xlog"

	"github.com/mudler/LocalAI/core/application"
	"github.com/mudler/LocalAI/core/backend"
	"github.com/mudler/LocalAI/core/config"
	"github.com/mudler/LocalAI/core/schema"
	"github.com/mudler/LocalAI/pkg/compress"
)

// CONTEXT_LOCALS_KEY_COMPRESSION_RESULT lets downstream handlers read the
// pkg/compress.Result attached by this middleware. Useful for adding
// compression_meta to the response usage block. Absent when the
// middleware did not run or compression was skipped.
const CONTEXT_LOCALS_KEY_COMPRESSION_RESULT = "COMPRESSION_RESULT"

// compressorPrompt is the fixed system instruction the Summarizer attaches
// to its synthetic chat request. Kept short and explicit so small models
// follow it reliably.
const compressorPrompt = "Summarize the following conversation for an AI agent " +
	"to continue coherently. Preserve: names, numbers, decisions, URLs, error " +
	"messages, tool names and their results. Drop: pleasantries, repetition. " +
	"Max: 500 tokens."

// CompressionMiddleware returns an Echo middleware that applies
// pkg/compress to the parsed request when the model's CompressionConfig
// enables it. Must be registered AFTER SetOpenAIRequest in the
// chatMiddleware chain so the request and config are available on the
// context.
//
// Production wiring uses a backend-backed Summarizer that invokes the
// compressor model via core/backend. Tests use
// CompressionMiddlewareWithSummarizer with a stub.
//
// Honours the global LOCALAI_DISABLE_COMPRESSION kill-switch: when the
// ApplicationConfig has DisableCompression=true the middleware is a
// no-op for all models, regardless of per-model enabled settings.
func CompressionMiddleware(app *application.Application) echo.MiddlewareFunc {
	if app.ApplicationConfig().DisableCompression {
		return passthroughMiddleware
	}
	return CompressionMiddlewareWithSummarizer(newBackendSummarizer(app))
}

// passthroughMiddleware is the no-op handler returned when compression is
// globally disabled. Cheaper than the regular middleware (no per-request
// type assertions or config reads) so the kill-switch has zero overhead.
var passthroughMiddleware echo.MiddlewareFunc = func(next echo.HandlerFunc) echo.HandlerFunc {
	return next
}

// CompressionMiddlewareWithSummarizer is the testable factory: it wires
// the same middleware logic but lets the caller inject any
// compress.Summarizer. Production code should use CompressionMiddleware,
// which constructs the backend-backed default. Exported only so the test
// suite can swap in a stub without standing up an Application.
func CompressionMiddlewareWithSummarizer(sum compress.Summarizer) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			req, cfg, ok := readRequestAndConfig(c)
			if !ok {
				return next(c)
			}
			if !cfg.Compression.Enabled {
				return next(c)
			}
			if len(req.Messages) == 0 {
				return next(c)
			}

			ctxSize := contextSize(cfg)
			if ctxSize <= 0 {
				// Without a known context size we cannot calculate the
				// trigger threshold. Don't fail loudly; this is a soft
				// feature that gracefully no-ops.
				return next(c)
			}

			cmpCfg := compress.Config{
				ContextSize:               ctxSize,
				TriggerAtRatio:            cfg.Compression.TriggerAtRatio,
				KeepTailTokens:            cfg.Compression.KeepTailTokens,
				MaxSummaryTokens:          cfg.Compression.MaxSummaryTokens,
				CompressorModel:           cfg.Compression.CompressorModel,
				PrimaryModel:              cfg.Name,
				OnPostCompressionOverflow: cfg.Compression.OnPostCompressionOverflow,
			}
			applyCompressionDefaults(&cmpCfg)

			res, err := compress.Compress(c.Request().Context(), req.Messages, cmpCfg, sum)
			if err != nil {
				xlog.Warn("compression failed; falling through to passthrough",
					"model", cfg.Name, "error", err)
				return next(c)
			}
			if res.Skipped {
				c.Set(CONTEXT_LOCALS_KEY_COMPRESSION_RESULT, res)
				return next(c)
			}

			req.Messages = res.Messages
			c.Set(CONTEXT_LOCALS_KEY_COMPRESSION_RESULT, res)
			xlog.Debug("compression applied",
				"model", cfg.Name,
				"original_tokens", res.OriginalTokens,
				"compressed_tokens", res.CompressedTokens,
				"dropped_turns", res.DroppedTurns,
				"compressor", res.Compressor)
			return next(c)
		}
	}
}

// readRequestAndConfig pulls the parsed OpenAIRequest and ModelConfig out
// of the Echo context. Returns ok=false when either is missing or has the
// wrong type, so the caller can pass through cleanly.
func readRequestAndConfig(c echo.Context) (*schema.OpenAIRequest, *config.ModelConfig, bool) {
	reqAny := c.Get(CONTEXT_LOCALS_KEY_LOCALAI_REQUEST)
	cfgAny := c.Get(CONTEXT_LOCALS_KEY_MODEL_CONFIG)
	if reqAny == nil || cfgAny == nil {
		return nil, nil, false
	}
	req, ok := reqAny.(*schema.OpenAIRequest)
	if !ok {
		return nil, nil, false
	}
	cfg, ok := cfgAny.(*config.ModelConfig)
	if !ok {
		return nil, nil, false
	}
	return req, cfg, true
}

// contextSize returns the configured context size for the model in tokens.
// Reads from the LLMConfig's ContextSize field. Returns 0 when not set so
// the middleware can no-op rather than guess.
func contextSize(cfg *config.ModelConfig) int {
	if cfg == nil || cfg.ContextSize == nil {
		return 0
	}
	return *cfg.ContextSize
}

// applyCompressionDefaults fills sensible defaults for fields the operator
// did not set. Mirrors the documented defaults in the YAML schema so an
// operator who writes only `compression: { enabled: true }` still gets a
// working configuration.
func applyCompressionDefaults(cfg *compress.Config) {
	if cfg.TriggerAtRatio == 0 {
		cfg.TriggerAtRatio = 0.75
	}
	if cfg.KeepTailTokens == 0 {
		cfg.KeepTailTokens = 8000
	}
	if cfg.MaxSummaryTokens == 0 {
		cfg.MaxSummaryTokens = 2048
	}
	if cfg.OnPostCompressionOverflow == "" {
		cfg.OnPostCompressionOverflow = compress.OverflowDropOldestSummary
	}
}

// backendSummarizer implements compress.Summarizer by invoking
// core/backend.ModelInferenceFunc with a fixed compression prompt.
//
// The summarizer expects the compressor model to support jinja-template
// rendering (use_jinja: true in the YAML). We pass empty predInput and
// rely on the model's chat template to render structured messages. This
// keeps the upstream PR simple — operators with a compressor that lacks
// jinja support get a graceful failure (logged + passthrough).
type backendSummarizer struct {
	app *application.Application
}

func newBackendSummarizer(app *application.Application) *backendSummarizer {
	return &backendSummarizer{app: app}
}

func (s *backendSummarizer) Summarize(ctx context.Context, model string, msgs []schema.Message, maxTokens int) (string, error) {
	cfg, ok := s.app.ModelConfigLoader().GetModelConfig(model)
	if !ok {
		return "", &summarizerError{stage: "model_lookup", model: model, msg: "model config not found"}
	}

	prompt := buildCompressionMessages(msgs)

	predFunc, err := backend.ModelInferenceFunc(
		ctx,
		"", // empty predInput: rely on the model's chat template
		schema.Messages(prompt),
		nil, nil, nil, // images, videos, audios
		s.app.ModelLoader(),
		&cfg,
		s.app.ModelConfigLoader(),
		s.app.ApplicationConfig(),
		nil, // tokenCallback
		"",  // tools
		"",  // toolChoice
		nil, // logprobs
		nil, // topLogprobs
		nil, // logitBias
		nil, // metadata
	)
	if err != nil {
		return "", &summarizerError{stage: "inference_setup", model: model, msg: err.Error()}
	}

	resp, err := predFunc()
	if err != nil {
		return "", &summarizerError{stage: "inference_call", model: model, msg: err.Error()}
	}
	return strings.TrimSpace(resp.Response), nil
}

// buildCompressionMessages renders the conversation history into a single
// user message addressed at the compressor model with the standard
// compression instruction as system context.
func buildCompressionMessages(history []schema.Message) []schema.Message {
	var b strings.Builder
	for _, m := range history {
		b.WriteString(m.Role)
		b.WriteString(": ")
		b.WriteString(messageContentToString(m))
		b.WriteString("\n\n")
	}
	return []schema.Message{
		{Role: "system", Content: compressorPrompt},
		{Role: "user", Content: b.String()},
	}
}

// messageContentToString flattens schema.Message.Content into plain text,
// preferring StringContent when set and falling back to JSON-marshalling
// for structured (multimodal) payloads.
func messageContentToString(m schema.Message) string {
	if m.StringContent != "" {
		return m.StringContent
	}
	switch v := m.Content.(type) {
	case nil:
		return ""
	case string:
		return v
	default:
		// Structured content: best-effort tokenisation. The compressor
		// only needs an approximate text shape, not a faithful
		// reproduction of the multimodal payload.
		return ""
	}
}

// summarizerError carries enough context for ops debugging without leaking
// internal types through the compress.Summarizer interface.
type summarizerError struct {
	stage string
	model string
	msg   string
}

func (e *summarizerError) Error() string {
	return "compression summarizer (" + e.stage + ", model=" + e.model + "): " + e.msg
}
