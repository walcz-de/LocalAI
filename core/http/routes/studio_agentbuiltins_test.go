// SPDX-License-Identifier: MIT
//go:build auth

package routes_test

import (
	"net/http"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/mudler/LocalAI/core/services/studio"
)

// A saved agent's builtins_off switches groups of built-in tools off for
// every chat with the agent, and the chat cannot switch them back on.
var _ = Describe("Chats agents builtins_off", func() {
	var s *studioServer
	BeforeEach(func() {
		s = newStudioServerWith(newTestFiles(), func(d *studio.Deps) { d.Web = routeWeb{} })
	})

	saveAgent := func(body map[string]any) string {
		rec := s.do("alice", http.MethodPost, "/api/chats/agents", body)
		Expect(rec.Code).To(Equal(http.StatusCreated), rec.Body.String())
		return decodeJSON(rec)["id"].(string)
	}
	chatWith := func(agentID string) string {
		rec := s.do("alice", http.MethodPost, "/api/chats", map[string]any{"model": "test-model", "agent_id": agentID})
		Expect(rec.Code).To(Equal(http.StatusCreated), rec.Body.String())
		return decodeJSON(rec)["id"].(string)
	}

	It("stores the groups, returns them and refuses a name that is not a group", func() {
		id := saveAgent(map[string]any{"name": "Intern", "builtins_off": []string{"web"}})
		got := s.do("alice", http.MethodGet, "/api/chats/agents/"+id, nil)
		Expect(got.Code).To(Equal(http.StatusOK))
		Expect(decodeJSON(got)["builtins_off"]).To(Equal([]any{"web"}))

		// A replace without the field keeps it, so a client that does not know
		// it cannot give the agent the web back; an empty list clears it.
		put := s.do("alice", http.MethodPut, "/api/chats/agents/"+id, map[string]any{"name": "Intern", "instructions": "Never use the web."})
		Expect(put.Code).To(Equal(http.StatusOK), put.Body.String())
		Expect(decodeJSON(put)["builtins_off"]).To(Equal([]any{"web"}))
		put = s.do("alice", http.MethodPut, "/api/chats/agents/"+id, map[string]any{"name": "Intern", "builtins_off": []string{}})
		Expect(put.Code).To(Equal(http.StatusOK), put.Body.String())
		Expect(decodeJSON(put)["builtins_off"]).To(Equal([]any{}))

		bad := s.do("alice", http.MethodPost, "/api/chats/agents", map[string]any{"name": "Bad", "builtins_off": []string{"bash"}})
		Expect(bad.Code).To(Equal(http.StatusBadRequest), bad.Body.String())
		Expect(bad.Body.String()).To(ContainSubstring("bash"))
		bad = s.do("alice", http.MethodPut, "/api/chats/agents/"+id, map[string]any{"name": "Intern", "builtins_off": []string{"nope"}})
		Expect(bad.Code).To(Equal(http.StatusBadRequest), bad.Body.String())

		plain := saveAgent(map[string]any{"name": "Plain"})
		Expect(decodeJSON(s.do("alice", http.MethodGet, "/api/chats/agents/"+plain, nil))["builtins_off"]).To(Equal([]any{}))
	})

	It("reports the groups off and not usable in the draft and in the chat, and the chat cannot switch them on", func() {
		id := saveAgent(map[string]any{"name": "Intern", "builtins_off": []string{"web"}})

		draft := s.do("alice", http.MethodGet, "/api/chats/draft/tools?model=test-model&agent_id="+id, nil)
		Expect(draft.Code).To(Equal(http.StatusOK), draft.Body.String())
		web := groupOf(decodeJSON(draft), "web")
		Expect(web).To(And(HaveKeyWithValue("off", true), Not(HaveKeyWithValue("usable", true))))
		Expect(web["reason"]).To(ContainSubstring(`the saved agent "Intern" switches it off`))

		chat := chatWith(id)
		panel := s.do("alice", http.MethodGet, "/api/chats/"+chat+"/tools", nil)
		Expect(panel.Code).To(Equal(http.StatusOK), panel.Body.String())
		Expect(groupOf(decodeJSON(panel), "web")).To(And(HaveKeyWithValue("off", true), Not(HaveKeyWithValue("usable", true))))

		path := "/api/chats/" + chat + "/builtins"
		on := s.do("alice", http.MethodPut, path, map[string]any{"off": []string{}})
		Expect(on.Code).To(Equal(http.StatusBadRequest), on.Body.String())
		Expect(on.Body.String()).To(ContainSubstring(`the saved agent \"Intern\" switches web off`))

		other := s.do("alice", http.MethodPut, path, map[string]any{"off": []string{"web", "subagents"}})
		Expect(other.Code).To(Equal(http.StatusOK), other.Body.String())
		Expect(groupOf(decodeJSON(other), "subagents")).To(HaveKeyWithValue("off", true))
		Expect(groupOf(decodeJSON(other), "web")).To(HaveKeyWithValue("off", true))
	})

	It("carries the groups through an export and an import", func() {
		id := saveAgent(map[string]any{"name": "Intern", "builtins_off": []string{"web"}})
		exp := s.do("alice", http.MethodGet, "/api/chats/agents/"+id+"/export", nil)
		Expect(exp.Code).To(Equal(http.StatusOK))
		file := decodeJSON(exp)
		Expect(file["agent"]).To(HaveKeyWithValue("builtins_off", []any{"web"}))
		imp := s.do("bob", http.MethodPost, "/api/chats/agents/import", file)
		Expect(imp.Code).To(Equal(http.StatusCreated), imp.Body.String())
		Expect(decodeJSON(imp)["agent"]).To(HaveKeyWithValue("builtins_off", []any{"web"}))
	})

	It("leaves a chat with an agent without builtins_off as before", func() {
		id := saveAgent(map[string]any{"name": "Researcher"})
		draft := s.do("alice", http.MethodGet, "/api/chats/draft/tools?model=test-model&agent_id="+id, nil)
		Expect(groupOf(decodeJSON(draft), "web")).To(And(HaveKeyWithValue("off", false), HaveKeyWithValue("usable", true)))

		chat := chatWith(id)
		path := "/api/chats/" + chat + "/builtins"
		Expect(s.do("alice", http.MethodPut, path, map[string]any{"off": []string{"web"}}).Code).To(Equal(http.StatusOK))
		back := s.do("alice", http.MethodPut, path, map[string]any{"off": []string{}})
		Expect(back.Code).To(Equal(http.StatusOK), back.Body.String())
		Expect(groupOf(decodeJSON(back), "web")).To(And(HaveKeyWithValue("off", false), HaveKeyWithValue("usable", true)))
	})
})
