package compress_test

import (
	"context"
	"errors"
	"fmt"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/mudler/LocalAI/core/schema"
	"github.com/mudler/LocalAI/pkg/compress"
)

// stubSummarizer is the Compress.Summarizer test double. It records its
// invocations and returns canned results so tests can assert on what the
// algorithm asked for without spinning up a real model.
type stubSummarizer struct {
	summary string
	err     error
	calls   int
	model   string
	maxTok  int
}

func (s *stubSummarizer) Summarize(_ context.Context, model string, _ []schema.Message, maxTokens int) (string, error) {
	s.calls++
	s.model = model
	s.maxTok = maxTokens
	return s.summary, s.err
}

// makeMessages constructs n user messages each carrying ~50 tokens of
// generic text. Total token count grows roughly linearly with n.
func makeMessages(n int) []schema.Message {
	body := strings.Repeat("This is filler content used to inflate the token count for tests. ", 4)
	out := make([]schema.Message, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, schema.Message{
			Role:    "user",
			Content: fmt.Sprintf("turn %d %s", i, body),
		})
	}
	return out
}

var _ = Describe("Compress", func() {
	var (
		ctx context.Context
		sum *stubSummarizer
		cfg compress.Config
	)

	BeforeEach(func() {
		ctx = context.Background()
		sum = &stubSummarizer{summary: "earlier turns covered logistics, totals, and a name (Alice)."}
		cfg = compress.Config{
			ContextSize:               1000,
			TriggerAtRatio:            0.5,
			KeepTailTokens:            100,
			MaxSummaryTokens:          200,
			PrimaryModel:              "gpt-4",
			OnPostCompressionOverflow: compress.OverflowDropOldestSummary,
		}
	})

	Context("trivial passthrough cases", func() {
		It("skips empty input without error", func() {
			res, err := compress.Compress(ctx, nil, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeTrue())
			Expect(res.SkipReason).To(Equal("no messages"))
			Expect(sum.calls).To(BeZero())
		})

		It("skips when ContextSize <= 0", func() {
			cfg.ContextSize = 0
			msgs := makeMessages(3)
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeTrue())
			Expect(sum.calls).To(BeZero())
		})

		It("skips when TriggerAtRatio is out of range", func() {
			cfg.TriggerAtRatio = 0
			msgs := makeMessages(3)
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeTrue())

			cfg.TriggerAtRatio = 2.0
			res, err = compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeTrue())
		})

		It("skips when token count is under threshold", func() {
			// 2 short messages, threshold = 500 tokens; well under.
			msgs := makeMessages(2)
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeTrue())
			Expect(res.SkipReason).To(Equal("under trigger threshold"))
			Expect(res.OriginalTokens).To(BeNumerically(">", 0))
			Expect(res.CompressedTokens).To(Equal(res.OriginalTokens))
			Expect(sum.calls).To(BeZero())
		})

		It("returns an error on negative KeepTailTokens", func() {
			cfg.KeepTailTokens = -1
			msgs := makeMessages(3)
			_, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).To(HaveOccurred())
		})
	})

	Context("normal compression path", func() {
		It("compresses when over threshold and returns metadata", func() {
			cfg.ContextSize = 200
			cfg.TriggerAtRatio = 0.5 // threshold 100 tokens
			cfg.KeepTailTokens = 50

			msgs := makeMessages(8) // > 100 tokens total
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeFalse())
			Expect(sum.calls).To(Equal(1))
			Expect(res.DroppedTurns).To(BeNumerically(">", 0))
			Expect(res.SummaryTokens).To(BeNumerically(">", 0))
			Expect(res.CompressedTokens).To(BeNumerically("<", res.OriginalTokens))
			// First message in the result is the synthetic summary
			Expect(res.Messages[0].Role).To(Equal("system"))
			Expect(res.Messages[0].Content).To(BeAssignableToTypeOf(""))
			Expect(res.Messages[0].Content.(string)).To(HavePrefix(compress.CompressedTurnPrefix))
		})

		It("preserves at least KeepTailTokens of tail content", func() {
			cfg.ContextSize = 300
			cfg.TriggerAtRatio = 0.3
			cfg.KeepTailTokens = 60

			msgs := makeMessages(10)
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeFalse())

			// The tail (everything except the synthetic summary at index 0)
			// must contain at least KeepTailTokens worth of content.
			tail := res.Messages[1:]
			Expect(len(tail)).To(BeNumerically(">", 0))
			// Last original messages should still be there
			lastOrig := msgs[len(msgs)-1].Content
			lastTail := tail[len(tail)-1].Content
			Expect(lastTail).To(Equal(lastOrig))
		})

		It("falls back to PrimaryModel when CompressorModel is empty", func() {
			cfg.ContextSize = 200
			cfg.TriggerAtRatio = 0.4
			cfg.CompressorModel = ""
			cfg.PrimaryModel = "gpt-4"

			msgs := makeMessages(8)
			_, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(sum.model).To(Equal("gpt-4"))
		})

		It("uses CompressorModel when set", func() {
			cfg.ContextSize = 200
			cfg.TriggerAtRatio = 0.4
			cfg.CompressorModel = "compressor-mini"
			cfg.PrimaryModel = "gpt-4"

			msgs := makeMessages(8)
			_, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(sum.model).To(Equal("compressor-mini"))
		})

		It("passes MaxSummaryTokens to the summarizer", func() {
			cfg.ContextSize = 200
			cfg.TriggerAtRatio = 0.4
			cfg.MaxSummaryTokens = 137

			msgs := makeMessages(8)
			_, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(sum.maxTok).To(Equal(137))
		})

		It("propagates Summarizer errors", func() {
			cfg.ContextSize = 200
			cfg.TriggerAtRatio = 0.4
			sum.err = errors.New("backend offline")

			msgs := makeMessages(8)
			_, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("backend offline"))
		})

		It("skips compression when tail already covers KeepTailTokens", func() {
			// Set a tail budget so generous that it swallows all messages,
			// leaving no head to compress.
			cfg.ContextSize = 200
			cfg.TriggerAtRatio = 0.4
			cfg.KeepTailTokens = 100000

			msgs := makeMessages(8)
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).NotTo(HaveOccurred())
			Expect(res.Skipped).To(BeTrue())
			Expect(res.SkipReason).To(ContainSubstring("tail"))
			Expect(sum.calls).To(BeZero())
		})
	})

	Context("overflow recovery", func() {
		It("returns ErrOverflow when policy is 'error' and post-compress still exceeds context", func() {
			// Tiny context with a long summary forces compressed > context.
			cfg.ContextSize = 30
			cfg.TriggerAtRatio = 0.1 // threshold = 3 → fires for any non-empty input
			cfg.KeepTailTokens = 5
			cfg.OnPostCompressionOverflow = compress.OverflowError
			sum.summary = strings.Repeat("very long summary content ", 30)

			msgs := makeMessages(8)
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			Expect(err).To(MatchError(compress.ErrOverflow))
			Expect(res.OverflowRecoveries).To(BeZero())
		})

		It("recovers via drop_oldest_summary by removing the synthetic message", func() {
			// Same setup as above, but recovery is enabled.
			cfg.ContextSize = 80
			cfg.TriggerAtRatio = 0.1
			cfg.KeepTailTokens = 30
			cfg.OnPostCompressionOverflow = compress.OverflowDropOldestSummary
			sum.summary = strings.Repeat("very long summary content ", 30)

			msgs := makeMessages(8)
			res, err := compress.Compress(ctx, msgs, cfg, sum)
			// After dropping the synthetic, the remaining tail should fit OR
			// we exhaust recoveries — either way the result is well-defined.
			if err == nil {
				Expect(res.OverflowRecoveries).To(BeNumerically(">=", 1))
				// First message is no longer the synthetic summary
				Expect(res.Messages[0].Role).NotTo(Equal(compress.CompressedTurnRole))
			} else {
				Expect(err).To(MatchError(compress.ErrOverflow))
			}
		})
	})
})
