package bridge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/activity"
	"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

// member is one speaker in an agent or party chat.
type member struct {
	ID, Name, Model, System string
}

func (s *Server) memberFor(id string) member {
	if strings.HasPrefix(id, "model:") {
		m := strings.TrimPrefix(id, "model:")
		return member{ID: id, Name: m, Model: m}
	}
	for _, a := range s.St.Agents {
		if a.ID == id {
			m := a.Model
			if m == "" {
				m = "vortex-mini"
			}
			return member{ID: a.ID, Name: a.Name, Model: m, System: a.SystemPrompt}
		}
	}
	return member{ID: id, Name: "Vortex", Model: "vortex-mini"}
}

// complete runs one chat completion against the endpoint for agentID (with gateway retry while models load).
func (s *Server) complete(agentID, model string, msgs []map[string]string, maxTok int) (string, error) {
	base, key := s.resolveEndpoint(agentID)
	raw, _ := json.Marshal(map[string]any{"model": model, "messages": msgs, "temperature": 0.4, "max_tokens": maxTok})
	cli := &http.Client{Timeout: 600 * time.Second}
	for attempt := 0; ; attempt++ {
		req, _ := http.NewRequest("POST", base+"/chat/completions", bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		r, err := cli.Do(req)
		if err != nil {
			return "", err
		}
		if r.StatusCode >= 500 && attempt < 2 {
			r.Body.Close()
			time.Sleep(time.Duration(6*(attempt+1)) * time.Second)
			continue
		}
		b, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		r.Body.Close()
		var p struct {
			Choices []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		json.Unmarshal(b, &p)
		if len(p.Choices) == 0 || p.Choices[0].Message.Content == "" {
			if r.StatusCode >= 500 {
				return "", fmt.Errorf("Vortex is loading this model on the server (retried 3×). Please send again in a few seconds.")
			}
			return "", fmt.Errorf("HTTP %d", r.StatusCode)
		}
		return p.Choices[0].Message.Content, nil
	}
}

// transcriptFor builds the message list as seen by one member: its own turns are "assistant",
// everyone else's (user and other agents) are "user" lines prefixed with the speaker.
func transcriptFor(me member, others []string, c *store.Chat, hint string) []map[string]string {
	sys := me.System
	if sys == "" {
		sys = "You are " + me.Name + "."
	}
	if len(others) > 0 {
		sys += "\nYou are in a group chat with the user and: " + strings.Join(others, ", ") +
			". Reply as " + me.Name + " only, briefly, building on what others said. Do not speak for the others."
	}
	if hint != "" {
		sys += "\n" + hint
	}
	out := []map[string]string{{"role": "system", "content": sys}}
	for _, m := range c.Messages {
		switch {
		case m.Role == "assistant" && m.Name == me.Name:
			out = append(out, map[string]string{"role": "assistant", "content": m.Content})
		case m.Role == "assistant":
			out = append(out, map[string]string{"role": "user", "content": "[" + m.Name + "]: " + m.Content})
		default:
			out = append(out, map[string]string{"role": "user", "content": m.Content})
		}
	}
	return out
}

// groupSend handles agent chats (one member) and party chats (members reply in turn).
func (s *Server) groupSend(c *store.Chat, comp store.Composer) map[string]any {
	ids := c.Members
	if c.Kind == "agent" {
		ids = []string{c.AgentID}
	}
	ms := make([]member, 0, len(ids))
	for _, id := range ids {
		ms = append(ms, s.memberFor(id))
	}
	maxTok, hint := lengthParams(comp)
	replies := []map[string]string{}
	for _, me := range ms {
		others := []string{}
		for _, o := range ms {
			if o.ID != me.ID {
				others = append(others, o.Name)
			}
		}
		model := me.Model
		if comp.Quick && strings.HasPrefix(model, "vortex") {
			model = "vortex-mini"
		}
		agentID := me.ID
		if strings.HasPrefix(agentID, "model:") {
			agentID = ""
		}
		reply, err := s.complete(agentID, model, transcriptFor(me, others, c, hint), maxTok)
		if err != nil {
			reply = "(" + me.Name + " could not reply: " + err.Error() + ")"
		}
		c.Messages = append(c.Messages, store.Msg{Role: "assistant", Name: me.Name, Content: reply})
		if agentID != "" {
			s.Act.Append(activity.Event{AgentID: agentID, Agent: me.Name, Kind: "chat", Summary: "Replied in " + c.Title, Detail: reply})
		}
		replies = append(replies, map[string]string{"name": me.Name, "content": reply})
		c.Updated = time.Now()
		s.St.SaveChat(*c) // persist after each speaker so the UI can stream turns
	}
	last := ""
	if len(replies) > 0 {
		last = replies[len(replies)-1]["content"]
	}
	return map[string]any{"reply": last, "replies": replies}
}

// agentChat opens (or creates) the sidebar chat for an agent.
func (s *Server) agentChat(agentID string) map[string]any {
	if agentID == "" {
		return map[string]any{"ok": false, "message": "Pick an agent."}
	}
	for _, c := range s.St.Chats {
		if c.Kind == "agent" && c.AgentID == agentID {
			return map[string]any{"ok": true, "id": c.ID}
		}
	}
	m := s.memberFor(agentID)
	c := store.Chat{ID: fmt.Sprintf("a-%d", time.Now().UnixNano()), Title: m.Name, Kind: "agent", AgentID: agentID, Updated: time.Now()}
	s.St.SaveChat(c)
	return map[string]any{"ok": true, "id": c.ID}
}

// partyNew creates a party chat with agents and/or models ("model:<id>").
func (s *Server) partyNew(title string, members []string) map[string]any {
	if len(members) < 2 {
		return map[string]any{"ok": false, "message": "Pick at least two agents or models."}
	}
	if title == "" {
		names := []string{}
		for _, id := range members {
			names = append(names, s.memberFor(id).Name)
		}
		title = "Party: " + strings.Join(names, ", ")
	}
	c := store.Chat{ID: fmt.Sprintf("p-%d", time.Now().UnixNano()), Title: title, Kind: "party", Members: members, Updated: time.Now()}
	s.St.SaveChat(c)
	return map[string]any{"ok": true, "id": c.ID}
}
