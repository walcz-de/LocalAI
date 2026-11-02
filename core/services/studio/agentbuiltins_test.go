package studio_test

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/mudler/LocalAI/core/services/studio"
	"github.com/mudler/LocalAI/core/services/studio/agents"
	"github.com/mudler/LocalAI/core/services/studio/builtins"
	"github.com/mudler/LocalAI/core/services/studio/studiotest"
	"github.com/mudler/LocalAI/core/services/studio/workspace"
)

// A saved agent can switch groups of built-in tools off for every chat that
// runs it: the chats the person starts with it, its trigger runs and its runs
// as a sub-agent. The chat cannot switch them back on.
var _ = Describe("built-in tool groups a saved agent switches off", func() {
	ctx := context.Background()

	// rig is a service with the web tools on and a store of saved agents.
	rig := func(script func(workspace.Actor, string) []studiotest.ToolStep) (*studio.Service, *studiotest.ToolHarness) {
		as, err := agents.NewJSON("")
		Expect(err).NotTo(HaveOccurred())
		return newToolService(script, withWeb(&fakeWeb{search: true, fetch: true}), func(d *studio.Deps) { d.Agents = as })
	}
	save := func(svc *studio.Service, a agents.Agent) agents.Agent {
		saved, err := svc.SaveAgent(ctx, alice, a)
		Expect(err).NotTo(HaveOccurred())
		return saved
	}
	chatWith := func(svc *studio.Service, agentID string) string {
		rec, err := svc.Create(ctx, alice, studio.CreateInput{Model: "m", AgentID: agentID})
		Expect(err).NotTo(HaveOccurred())
		return rec.ID
	}
	panelGroup := func(svc *studio.Service, id, group string) studio.BuiltinGroup {
		p, err := svc.Tools(ctx, alice, id)
		Expect(err).NotTo(HaveOccurred())
		return builtinGroup(p.Builtins, group)
	}

	It("stores the groups, keeps an opt-in one and refuses a name that is not a group", func() {
		svc, _ := rig(sayOK)
		a := save(svc, agents.Agent{Name: "Intern", BuiltinsOff: []string{"web", "web", builtins.GroupSavedAgents}})
		got, err := svc.Agent(ctx, alice, a.ID)
		Expect(err).NotTo(HaveOccurred())
		Expect(got.BuiltinsOff).To(Equal([]string{"web", builtins.GroupSavedAgents}), "deduplicated; the opt-in group is kept, so it stays off")

		_, err = svc.SaveAgent(ctx, alice, agents.Agent{Name: "Bad", BuiltinsOff: []string{"bash"}})
		Expect(err).To(MatchError(studio.ErrBadBuiltinGroup))
	})

	It("gives a chat with the agent no web tools from its first turn, and the chat cannot switch them on", func() {
		svc, h := rig(sayOK)
		a := save(svc, agents.Agent{Name: "Intern", BuiltinsOff: []string{"web"}})

		draft, err := svc.DraftTools(ctx, alice, "m", a.ID)
		Expect(err).NotTo(HaveOccurred())
		g := builtinGroup(draft.Builtins, "web")
		Expect(g.Off).To(BeTrue(), "draft: %+v", g)
		Expect(g.Usable).To(BeFalse(), "draft: %+v", g)
		Expect(g.Reason).To(ContainSubstring(`the saved agent "Intern" switches it off`))

		id := chatWith(svc, a.ID)
		g = panelGroup(svc, id, "web")
		Expect(g.Off).To(BeTrue())
		Expect(g.Usable).To(BeFalse())
		turnPrompt(svc, h, id)
		Expect(h.ToolNames(id)).NotTo(ContainElements("web_search"))
		Expect(h.ToolNames(id)).NotTo(ContainElements("web_fetch"))

		// Leaving web out of the list would switch it on: refused, with the agent's name.
		err = svc.SetBuiltinsOff(ctx, alice, id, nil)
		Expect(err).To(MatchError(studio.ErrAgentBuiltinOff))
		Expect(err.Error()).To(ContainSubstring(`"Intern"`))
		Expect(err.Error()).To(ContainSubstring("web"))
		Expect(svc.SetBuiltinsOff(ctx, alice, id, []string{builtins.GroupSubAgents})).To(MatchError(studio.ErrAgentBuiltinOff))

		// Another group still switches, as long as web stays in the list.
		Expect(svc.SetBuiltinsOff(ctx, alice, id, []string{"web", builtins.GroupSubAgents})).To(Succeed())
		Expect(panelGroup(svc, id, builtins.GroupSubAgents).Off).To(BeTrue())
		Expect(svc.SetBuiltinsOff(ctx, alice, id, []string{"web"})).To(Succeed())
		Expect(panelGroup(svc, id, builtins.GroupSubAgents).Off).To(BeFalse())
		sent(svc, alice, id, "again")
		idle(svc, alice, id)
		Expect(h.ToolNames(id)).NotTo(ContainElement("web_search"))
	})

	It("follows a change of the agent at the chat's next turn", func() {
		svc, h := rig(sayOK)
		a := save(svc, agents.Agent{Name: "Intern"})
		id := chatWith(svc, a.ID)
		turnPrompt(svc, h, id)
		Expect(h.ToolNames(id)).To(ContainElement("web_search"))

		a.BuiltinsOff = []string{"web"}
		save(svc, a)
		sent(svc, alice, id, "again")
		idle(svc, alice, id)
		Expect(h.ToolNames(id)).NotTo(ContainElement("web_search"))
		Expect(panelGroup(svc, id, "web").Usable).To(BeFalse())
	})

	It("keeps every group off when the agent is deleted", func() {
		svc, h := rig(sayOK)
		a := save(svc, agents.Agent{Name: "Intern", BuiltinsOff: []string{"web"}})
		id := chatWith(svc, a.ID)
		Expect(svc.DeleteAgent(ctx, alice, a.ID)).To(Succeed())
		turnPrompt(svc, h, id)
		Expect(h.ToolNames(id)).NotTo(ContainElement("web_search"))
		g := panelGroup(svc, id, "web")
		Expect(g.Off).To(BeTrue())
		Expect(g.Usable).To(BeFalse())
		Expect(g.Reason).To(Equal("the chat's saved agent is unavailable"))
	})

	It("keeps an opt-in group it lists off: the chat cannot switch it on", func() {
		svc, _ := rig(sayOK)
		a := save(svc, agents.Agent{Name: "Intern", BuiltinsOff: []string{builtins.GroupSavedAgents}})
		id := chatWith(svc, a.ID)
		Expect(svc.SetBuiltinsOn(ctx, alice, id, []string{builtins.GroupSavedAgents})).To(MatchError(studio.ErrAgentBuiltinOff))
		g := panelGroup(svc, id, builtins.GroupSavedAgents)
		Expect(g.Off).To(BeTrue())
		Expect(g.Usable).To(BeFalse())
		// The opt-in group does not lock the rest.
		Expect(svc.SetBuiltinsOff(ctx, alice, id, nil)).To(Succeed())
	})

	It("leaves a chat with an agent that switches nothing off exactly as before", func() {
		svc, h := rig(sayOK)
		a := save(svc, agents.Agent{Name: "Researcher"})
		got, err := svc.Agent(ctx, alice, a.ID)
		Expect(err).NotTo(HaveOccurred())
		Expect(got.BuiltinsOff).To(BeEmpty())

		draft, err := svc.DraftTools(ctx, alice, "m", a.ID)
		Expect(err).NotTo(HaveOccurred())
		Expect(builtinGroup(draft.Builtins, "web")).To(Equal(studio.BuiltinGroup{Group: "web", Tools: []string{"web_search", "web_fetch"}, Usable: true, Provider: "builtin",
			Providers: map[string]string{"web_search": "builtin", "web_fetch": "builtin"}}))

		id := chatWith(svc, a.ID)
		turnPrompt(svc, h, id)
		Expect(h.ToolNames(id)).To(ContainElements("web_search", "web_fetch"))
		Expect(svc.SetBuiltinsOff(ctx, alice, id, []string{"web"})).To(Succeed())
		Expect(svc.SetBuiltinsOff(ctx, alice, id, nil)).To(Succeed())
		Expect(svc.SetBuiltinsOn(ctx, alice, id, []string{builtins.GroupSavedAgents})).To(Succeed())
		Expect(panelGroup(svc, id, builtins.GroupSavedAgents).Off).To(BeFalse())
	})

	It("keeps the groups off for the agent started as a sub-agent of a plain chat", func() {
		svc, h := rig(savedAgentScript(`{"task":"check the draft","agent":"intern"}`))
		save(svc, agents.Agent{Name: "Intern", BuiltinsOff: []string{"web"}})
		id := create(svc, alice)
		allowSavedAgents(svc, id)
		sent(svc, alice, id, "go")
		idle(svc, alice, id)
		Expect(h.ToolNames(id)).To(ContainElement("web_search"), "the parent chat keeps the web")

		res := h.ResultsFor("spawn_agent")
		Expect(res).To(HaveLen(1))
		Expect(res[0].Err).NotTo(HaveOccurred())
		kids := childrenOf(svc, alice, id)
		Expect(kids).To(HaveLen(1))
		Expect(h.ToolNames(kids[0].ID)).NotTo(ContainElement("web_search"))
		Expect(h.ToolNames(kids[0].ID)).NotTo(ContainElement("web_fetch"))
	})

	It("gives the agent started as a sub-agent the web when it switches nothing off", func() {
		svc, h := rig(savedAgentScript(`{"task":"check the draft","agent":"researcher"}`))
		save(svc, agents.Agent{Name: "Researcher"})
		id := create(svc, alice)
		allowSavedAgents(svc, id)
		sent(svc, alice, id, "go")
		idle(svc, alice, id)
		kids := childrenOf(svc, alice, id)
		Expect(kids).To(HaveLen(1))
		Expect(h.ToolNames(kids[0].ID)).To(ContainElement("web_search"))
	})

	It("keeps the groups off for a sub-agent of a chat with the agent", func() {
		svc, h := rig(savedAgentScript(`{"task":"check the draft"}`))
		a := save(svc, agents.Agent{Name: "Intern", BuiltinsOff: []string{"web"}})
		id := chatWith(svc, a.ID)
		sent(svc, alice, id, "go")
		idle(svc, alice, id)
		res := h.ResultsFor("spawn_agent")
		Expect(res).To(HaveLen(1))
		Expect(res[0].Err).NotTo(HaveOccurred())
		kids := childrenOf(svc, alice, id)
		Expect(kids).To(HaveLen(1))
		Expect(h.ToolNames(kids[0].ID)).NotTo(ContainElement("web_search"))
	})
})

var _ = Describe("trigger runs of a saved agent that switches built-in groups off", func() {
	run := func(off []string) []string {
		sh := newShared()
		sh.deps = withWeb(&fakeWeb{search: true, fetch: true})
		r := sh.rig(saySummary, studio.TriggerOptions{})
		ag, err := r.svc.SaveAgent(context.Background(), alice, agents.Agent{Name: "Mail reader", BuiltinsOff: off})
		Expect(err).NotTo(HaveOccurred())
		tr := r.schedule(studio.TriggerInput{AgentID: ag.ID})
		r.due()
		return r.h.ToolNames(r.waitEnded(tr.ID).ChatID)
	}

	It("runs without the groups", func() {
		got := run([]string{"web"})
		Expect(got).NotTo(ContainElement("web_search"), "tools = %v", got)
		Expect(got).NotTo(ContainElement("web_fetch"), "tools = %v", got)
	})

	It("runs with the web when the agent switches nothing off", func() {
		got := run(nil)
		Expect(got).To(ContainElement("web_search"), "tools = %v", got)
	})
})
