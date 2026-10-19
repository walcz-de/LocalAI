package tokens_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/mudler/LocalAI/core/schema"
	"github.com/mudler/LocalAI/pkg/tokens"
)

var _ = Describe("EncodingFor", func() {
	DescribeTable("model name resolution",
		func(model, expected string) {
			Expect(tokens.EncodingFor(model)).To(Equal(expected))
		},
		Entry("empty string falls back to cl100k_base", "", "cl100k_base"),
		Entry("gpt-4o exact match", "gpt-4o", "o200k_base"),
		Entry("gpt-4o-mini exact match", "gpt-4o-mini", "o200k_base"),
		Entry("gpt-4 exact match", "gpt-4", "cl100k_base"),
		Entry("gpt-4-turbo prefix", "gpt-4-turbo-2024-04-09", "cl100k_base"),
		Entry("gpt-4o-2024 prefix", "gpt-4o-2024-08-06", "o200k_base"),
		Entry("gpt-3.5-turbo prefix", "gpt-3.5-turbo-0125", "cl100k_base"),
		Entry("unknown model falls back", "Qwen3-30B-A3B-Instruct", "cl100k_base"),
		Entry("Llama variant falls back", "Meta-Llama-3.1-70B-Instruct", "cl100k_base"),
		Entry("Claude variant falls back", "claude-opus-4-7", "cl100k_base"),
	)
})

var _ = Describe("CountText", func() {
	It("returns 0 for an empty string without error", func() {
		n, err := tokens.CountText("", "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(Equal(0))
	})

	It("counts a non-empty ASCII string", func() {
		n, err := tokens.CountText("hello world", "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(BeNumerically(">", 0))
	})

	It("counts German umlauts without error", func() {
		n, err := tokens.CountText("Müller schickt eine Rechnung über 199,99 €.", "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(BeNumerically(">", 5))
	})

	It("works with an unknown model via fallback encoding", func() {
		n, err := tokens.CountText("hello world", "Qwen3-30B-A3B-Instruct")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(BeNumerically(">", 0))
	})

	It("produces the same count for the same text under matching encodings", func() {
		nA, _ := tokens.CountText("the quick brown fox", "gpt-4")
		nB, _ := tokens.CountText("the quick brown fox", "Qwen3-30B-A3B-Instruct")
		Expect(nA).To(Equal(nB))
	})

	It("counts more for longer text", func() {
		short, _ := tokens.CountText("short", "gpt-4")
		long, _ := tokens.CountText("this is a noticeably longer string with several words", "gpt-4")
		Expect(long).To(BeNumerically(">", short))
	})
})

var _ = Describe("Count", func() {
	It("returns 0 for an empty messages slice without error", func() {
		n, err := tokens.Count(nil, "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(Equal(0))
	})

	It("counts a single user message including primer and overhead", func() {
		messages := []schema.Message{
			{Role: "user", Content: "Hello!"},
		}
		n, err := tokens.Count(messages, "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		// primer (3) + per-message overhead (3) + role + content > 6
		Expect(n).To(BeNumerically(">", 6))
	})

	It("counts a multi-turn conversation correctly", func() {
		messages := []schema.Message{
			{Role: "system", Content: "You are a helpful assistant."},
			{Role: "user", Content: "What's the weather?"},
			{Role: "assistant", Content: "I cannot check live weather."},
		}
		n, err := tokens.Count(messages, "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(BeNumerically(">", 20))
	})

	It("respects the per-Name overhead", func() {
		base := []schema.Message{
			{Role: "user", Content: "Hello!"},
		}
		named := []schema.Message{
			{Role: "user", Name: "alice", Content: "Hello!"},
		}
		nBase, _ := tokens.Count(base, "gpt-4")
		nNamed, _ := tokens.Count(named, "gpt-4")
		Expect(nNamed).To(BeNumerically(">", nBase))
	})

	It("handles StringContent as content source", func() {
		messages := []schema.Message{
			{Role: "user", StringContent: "via string content field"},
		}
		n, err := tokens.Count(messages, "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(BeNumerically(">", 6))
	})

	It("handles structured Content (multimodal-shaped) without error", func() {
		messages := []schema.Message{
			{
				Role: "user",
				Content: []any{
					map[string]any{"type": "text", "text": "describe this image"},
				},
			},
		}
		n, err := tokens.Count(messages, "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(BeNumerically(">", 0))
	})

	It("includes tool_calls in the count", func() {
		base := []schema.Message{
			{Role: "assistant", Content: ""},
		}
		withTools := []schema.Message{
			{
				Role:    "assistant",
				Content: "",
				ToolCalls: []schema.ToolCall{
					{
						ID:   "call_001",
						Type: "function",
						FunctionCall: schema.FunctionCall{
							Name:      "get_weather",
							Arguments: `{"city":"Berlin"}`,
						},
					},
				},
			},
		}
		nBase, _ := tokens.Count(base, "gpt-4")
		nTools, _ := tokens.Count(withTools, "gpt-4")
		Expect(nTools).To(BeNumerically(">", nBase))
	})

	It("treats nil Content as empty", func() {
		messages := []schema.Message{
			{Role: "user", Content: nil},
		}
		n, err := tokens.Count(messages, "gpt-4")
		Expect(err).NotTo(HaveOccurred())
		// Just primer + per-message + role
		Expect(n).To(BeNumerically(">", 0))
	})

	It("works with an unknown model via fallback encoding", func() {
		messages := []schema.Message{
			{Role: "user", Content: "Hello"},
		}
		n, err := tokens.Count(messages, "some-unknown-model-xyz")
		Expect(err).NotTo(HaveOccurred())
		Expect(n).To(BeNumerically(">", 0))
	})
})
