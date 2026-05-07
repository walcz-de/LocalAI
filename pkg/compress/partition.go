package compress

import (
	"github.com/mudler/LocalAI/core/schema"
	"github.com/mudler/LocalAI/pkg/tokens"
)

// partition splits messages into a "compress head" and a "keep tail" such
// that the tail covers at least keepTailTokens (or, if the entire
// conversation is shorter than that, returns an empty head and the full
// list as the tail). Messages are walked back-to-front and added to the
// tail until the budget is met; remaining messages become the head.
//
// keepTailTokens == 0 keeps no tail and compresses everything, which is
// almost certainly not what the operator wants — Compress callers should
// pass a positive value.
func partition(messages []schema.Message, keepTailTokens int, model string) ([]schema.Message, []schema.Message, error) {
	if keepTailTokens <= 0 {
		// No tail preservation requested → compress everything.
		return messages, nil, nil
	}

	tailTokens := 0
	splitIdx := len(messages)

	for i := len(messages) - 1; i >= 0; i-- {
		mt, err := tokens.Count([]schema.Message{messages[i]}, model)
		if err != nil {
			return nil, nil, err
		}
		if tailTokens+mt > keepTailTokens && tailTokens > 0 {
			// Including this message would exceed the tail budget AND we
			// already have at least one message in the tail. Stop here:
			// the tail is everything from splitIdx onwards.
			break
		}
		tailTokens += mt
		splitIdx = i
		if tailTokens >= keepTailTokens {
			break
		}
	}

	head := messages[:splitIdx]
	tail := messages[splitIdx:]
	return head, tail, nil
}
