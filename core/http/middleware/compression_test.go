package middleware_test

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"

	"github.com/labstack/echo/v4"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/mudler/LocalAI/core/config"
	. "github.com/mudler/LocalAI/core/http/middleware"
	"github.com/mudler/LocalAI/core/schema"
	"github.com/mudler/LocalAI/pkg/compress"
)

// stubSummarizer is the test double for compress.Summarizer.
type stubSummarizer struct {
	summary string
	err     error
	calls   int
}

func (s *stubSummarizer) Summarize(_ context.Context, _ string, _ []schema.Message, _ int) (string, error) {
	s.calls++
	return s.summary, s.err
}

// fakeChatHandler records what its predecessor middleware passed through.
type fakeChatHandler struct {
	receivedRequest *schema.OpenAIRequest
	receivedResult  any
	called          bool
}

func (h *fakeChatHandler) handle(c echo.Context) error {
	h.called = true
	if v := c.Get(CONTEXT_LOCALS_KEY_LOCALAI_REQUEST); v != nil {
		if r, ok := v.(*schema.OpenAIRequest); ok {
			h.receivedRequest = r
		}
	}
	h.receivedResult = c.Get(CONTEXT_LOCALS_KEY_COMPRESSION_RESULT)
	return c.NoContent(http.StatusOK)
}

// installContext is a tiny middleware that primes the Echo context with
// a parsed *OpenAIRequest and *ModelConfig, mirroring what
// SetOpenAIRequest does in production. Used in tests to bypass the
// heavyweight RequestExtractor setup.
func installContext(req *schema.OpenAIRequest, cfg *config.ModelConfig) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			if req != nil {
				c.Set(CONTEXT_LOCALS_KEY_LOCALAI_REQUEST, req)
			}
			if cfg != nil {
				c.Set(CONTEXT_LOCALS_KEY_MODEL_CONFIG, cfg)
			}
			return next(c)
		}
	}
}

// makeChatRequest returns a request large enough to trigger compression
// against a small ContextSize. n controls message count.
func makeChatRequest(n int) *schema.OpenAIRequest {
	body := strings.Repeat("This is filler content used to inflate token count for tests. ", 4)
	msgs := make([]schema.Message, 0, n)
	for i := 0; i < n; i++ {
		msgs = append(msgs, schema.Message{
			Role:    "user",
			Content: fmt.Sprintf("turn %d %s", i, body),
		})
	}
	return &schema.OpenAIRequest{Messages: msgs}
}

// modelConfigWithCompression builds a ModelConfig with the given
// compression configuration and a small context size to make tests
// deterministic.
func modelConfigWithCompression(cmp config.CompressionConfig, contextSize int) *config.ModelConfig {
	cs := contextSize
	cfg := &config.ModelConfig{
		Name:        "test-model",
		Compression: cmp,
	}
	cfg.LLMConfig.ContextSize = &cs
	return cfg
}

// fireRequest plumbs through a one-shot Echo handler chain with a stub
// summarizer and returns the captured handler outcome.
func fireRequest(req *schema.OpenAIRequest, cfg *config.ModelConfig, sum compress.Summarizer) *fakeChatHandler {
	e := echo.New()
	h := &fakeChatHandler{}
	e.POST("/test", h.handle, installContext(req, cfg), CompressionMiddlewareWithSummarizer(sum))
	r := httptest.NewRequest(http.MethodPost, "/test", strings.NewReader("{}"))
	r.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, r)
	Expect(rec.Code).To(Equal(http.StatusOK))
	return h
}

var _ = Describe("CompressionMiddleware", func() {
	Context("passthrough cases", func() {
		It("does nothing when Compression.Enabled is false", func() {
			req := makeChatRequest(8)
			origMsgCount := len(req.Messages)
			cfg := modelConfigWithCompression(config.CompressionConfig{Enabled: false}, 200)
			sum := &stubSummarizer{summary: "should not be called"}

			h := fireRequest(req, cfg, sum)
			Expect(h.called).To(BeTrue())
			Expect(sum.calls).To(BeZero())
			Expect(len(h.receivedRequest.Messages)).To(Equal(origMsgCount))
			Expect(h.receivedResult).To(BeNil())
		})

		It("does nothing when context is missing the request", func() {
			cfg := modelConfigWithCompression(config.CompressionConfig{Enabled: true}, 200)
			sum := &stubSummarizer{summary: "should not be called"}
			h := fireRequest(nil, cfg, sum)
			Expect(h.called).To(BeTrue())
			Expect(sum.calls).To(BeZero())
		})

		It("does nothing when ContextSize is unset", func() {
			req := makeChatRequest(8)
			cfg := &config.ModelConfig{
				Name:        "test-model",
				Compression: config.CompressionConfig{Enabled: true, TriggerAtRatio: 0.5},
			}
			sum := &stubSummarizer{summary: "should not be called"}
			h := fireRequest(req, cfg, sum)
			Expect(h.called).To(BeTrue())
			Expect(sum.calls).To(BeZero())
		})

		It("skips when token count is under threshold", func() {
			req := makeChatRequest(2) // small
			cfg := modelConfigWithCompression(config.CompressionConfig{
				Enabled:        true,
				TriggerAtRatio: 0.5,
				KeepTailTokens: 50,
			}, 1000)
			sum := &stubSummarizer{summary: "unused"}

			h := fireRequest(req, cfg, sum)
			Expect(h.called).To(BeTrue())
			Expect(sum.calls).To(BeZero())
			res, ok := h.receivedResult.(compress.Result)
			Expect(ok).To(BeTrue())
			Expect(res.Skipped).To(BeTrue())
		})
	})

	Context("compression path", func() {
		It("compresses request messages and exposes the Result on context", func() {
			req := makeChatRequest(8)
			origCount := len(req.Messages)
			cfg := modelConfigWithCompression(config.CompressionConfig{
				Enabled:        true,
				TriggerAtRatio: 0.5,
				KeepTailTokens: 50,
			}, 200)
			sum := &stubSummarizer{summary: "earlier turns covered logistics, totals, and a name"}

			h := fireRequest(req, cfg, sum)
			Expect(h.called).To(BeTrue())
			Expect(sum.calls).To(Equal(1))
			// Messages list shrank
			Expect(len(h.receivedRequest.Messages)).To(BeNumerically("<", origCount))
			// First message is the synthetic summary
			Expect(h.receivedRequest.Messages[0].Role).To(Equal(compress.CompressedTurnRole))
			res, ok := h.receivedResult.(compress.Result)
			Expect(ok).To(BeTrue())
			Expect(res.Skipped).To(BeFalse())
			Expect(res.DroppedTurns).To(BeNumerically(">", 0))
		})

		It("falls through to passthrough when summarizer errors", func() {
			req := makeChatRequest(8)
			origCount := len(req.Messages)
			cfg := modelConfigWithCompression(config.CompressionConfig{
				Enabled:        true,
				TriggerAtRatio: 0.5,
				KeepTailTokens: 50,
			}, 200)
			sum := &stubSummarizer{err: errors.New("backend offline")}

			h := fireRequest(req, cfg, sum)
			Expect(h.called).To(BeTrue())
			Expect(sum.calls).To(Equal(1))
			// Messages unchanged because the request fell through to passthrough
			Expect(len(h.receivedRequest.Messages)).To(Equal(origCount))
		})

		It("applies sensible defaults when the operator only sets Enabled", func() {
			// Operator just sets enabled: true. Defaults should kick in.
			req := makeChatRequest(8)
			cfg := modelConfigWithCompression(config.CompressionConfig{
				Enabled: true,
				// All other fields zero — defaults expected
			}, 200)
			sum := &stubSummarizer{summary: "summary"}

			h := fireRequest(req, cfg, sum)
			// Default trigger_at_ratio is 0.75, and our request fits well under
			// that for context_size=200 → expect skipped, not invoked.
			Expect(h.called).To(BeTrue())
			Expect(sum.calls).To(BeZero())
		})
	})
})
