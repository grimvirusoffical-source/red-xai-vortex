package bridge

import (
    "strings"

    "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"
)

// Models are selected ONLY from ids returned by this user's authenticated
// gateway /models endpoint. No model or billing permission is invented.
var agentGenres = map[string][]string{
    "code": {"qwen2.5-coder-32b", "vortex-pro", "qwen2.5-coder-14b", "vortex-std", "vortex"},
    "reason": {"r1-distill-qwen-32b", "qwq-32b", "r1-distill-qwen-14b", "vortex-pro", "vortex"},
    "write": {"mistral-small-24b", "dolphin3-mistral-24b-q6k", "vortex"},
    "vision": {"gemma3-12b-vision", "qwen2.5-vl-7b", "vortex"},
    "general": {"vortex", "red-xai", "vortex-std", "vortex-mini"},
}

// Pick a specialist for the actual task, not just the first token such as
// "search" or "open" from a long, multi-step instruction.
func agentGenre(text string) string {
    t := strings.ToLower(text)
    switch {
    case hasAgentKeywords(t, "code", "typescript", "python", "github", "repository", "compile", "programming", "debug", "unit test", "javascript", "sql", "pull request"):
        return "code"
    case hasAgentKeywords(t, "prove", "mathematics", "logic", "reason", "analy", "calculate", "hypothesis", "research", "compare", "decide"):
        return "reason"
    case hasAgentKeywords(t, "write a story", "novel", "poem", "roleplay", "lyrics", "screenplay", "creative"):
        return "write"
    case hasAgentKeywords(t, "image", "photo", "picture", "visual", "screenshot"):
        return "vision"
    default:
        return "general"
    }
}

func hasAgentKeywords(text string, words ...string) bool {
    for _, word := range words {
        if strings.Contains(text, word) { return true }
    }
    return false
}

func availableAgentModels(a store.Agent, task string, available []string) (executor, planner string) {
    if a.Provider != "" && a.Provider != "vortex" {
        return a.Model, "" // external providers use ONLY the key the user supplied
    }
    if a.ModelMode == "" || a.ModelMode == "single" {
        return a.Model, ""
    }
    allowed := map[string]bool{}
    for _, name := range available { allowed[name] = true }
    // User-selected pool further narrows choices. Never silently expand it.
    if len(a.ModelPool) > 0 {
        pool := map[string]bool{}
        for _, name := range a.ModelPool { pool[name] = true }
        for name := range allowed { if !pool[name] { delete(allowed, name) } }
    }
    pick := func(ids []string) string {
        for _, id := range ids { if allowed[id] { return id } }
        return ""
    }
    executor = pick(agentGenres[agentGenre(task)])
    if executor == "" { executor = pick(agentGenres["general"]) }
    if executor == "" {
        for _, id := range available { if allowed[id] { executor = id; break } }
    }
    if executor == "" { return a.Model, "" } // gateway will report the real permission error
    if a.ModelMode == "mix" {
        // A second available specialist plans; the executor alone gets tools.
        order := append([]string{}, agentGenres["reason"]...)
        order = append(order, agentGenres["code"]...)
        order = append(order, agentGenres["general"]...)
        for _, id := range order {
            if id != executor && allowed[id] {
                planner = id
                break
            }
        }
    }
    return executor, planner
}

// A task that needs an actual GUI/browser interaction cannot be satisfied with
// fetch_url or a shell command. Don't claim to have performed it.
func requiresDesktopBrowser(task string) bool {
    t := strings.ToLower(task)
    return hasAgentKeywords(t, "discord", "send a message", "reply to a friend", "browser tab", "click the", "type into", "chrome tab", "dm ", "direct message")
}
