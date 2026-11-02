package studio_test

import (
	"os"
	"time"

	"github.com/mudler/LocalAI/core/services/studio"
	"github.com/mudler/LocalAI/core/services/studio/studiotest"
	"github.com/mudler/LocalAI/core/services/studio/workspace"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// chatAt is a chat service whose clock stands at now.
func chatAt(now time.Time) (*studio.Service, *studiotest.ToolHarness) {
	return newToolService(func(_ workspace.Actor, text string) []studiotest.ToolStep {
		if text == "go" {
			return []studiotest.ToolStep{{Tool: "spawn_agent", Args: `{"task":"find the answer","wait":true}`}, {Say: "parent done"}}
		}
		return []studiotest.ToolStep{{Say: "ok"}}
	}, func(d *studio.Deps) { d.Clock = func() time.Time { return now } })
}

var _ = Describe("today's date in the turn note", func() {
	berlin := time.FixedZone("Europe/Berlin", 3600)

	It("tells the model the weekday and the date of the clock, in the clock's zone", func() {
		svc, h := chatAt(time.Date(2026, 11, 2, 9, 30, 0, 0, berlin))
		id := create(svc, alice)
		turnWith(svc, id, "what day is it?")
		got := h.Received(id)
		Expect(got).To(HaveLen(1))
		Expect(got[0]).To(ContainSubstring("Today is Monday, 2 November 2026 (Europe/Berlin)."))
	})

	It("follows the clock: another day gives another line", func() {
		svc, h := chatAt(time.Date(2025, 2, 11, 9, 30, 0, 0, berlin))
		id := create(svc, alice)
		turnWith(svc, id, "what day is it?")
		got := h.Received(id)
		Expect(got).To(HaveLen(1))
		Expect(got[0]).To(ContainSubstring("Today is Tuesday, 11 February 2025 (Europe/Berlin)."))
		Expect(got[0]).NotTo(ContainSubstring("2026"))
	})

	It("keeps the date out of the system prompt, so the harness does not restart each day", func() {
		svc, h := chatAt(time.Date(2026, 11, 2, 9, 30, 0, 0, berlin))
		id := create(svc, alice)
		turnWith(svc, id, "hi")
		Expect(h.TurnPrompt(id)).NotTo(ContainSubstring("Today is"))
		Expect(h.TurnPrompt(id)).NotTo(ContainSubstring("2 November 2026"))
	})

	It("names the server's zone by TZ, since time.Local is only called Local", func() {
		old, had := os.LookupEnv("TZ")
		Expect(os.Setenv("TZ", "Europe/Berlin")).To(Succeed())
		DeferCleanup(func() {
			if had {
				os.Setenv("TZ", old)
			} else {
				os.Unsetenv("TZ")
			}
		})
		svc, h := chatAt(time.Date(2026, 11, 2, 12, 0, 0, 0, time.Local))
		id := create(svc, alice)
		turnWith(svc, id, "hi")
		Expect(h.Received(id)[0]).To(ContainSubstring("Today is Monday, 2 November 2026 (Europe/Berlin)."))
		Expect(h.Received(id)[0]).NotTo(ContainSubstring("(Local)"))
	})

	It("tells a sub-agent the date too", func() {
		svc, h := chatAt(time.Date(2026, 11, 2, 9, 30, 0, 0, berlin))
		id := create(svc, alice)
		turnWith(svc, id, "go")
		kids := childrenOf(svc, alice, id)
		Expect(kids).To(HaveLen(1))
		got := h.Received(kids[0].ID)
		Expect(got).NotTo(BeEmpty())
		Expect(got[0]).To(ContainSubstring("Today is Monday, 2 November 2026 (Europe/Berlin)."))
	})
})
