package bridge

import "github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/store"

// Tier is one step on the composer strength slider.
type Tier struct {
	ID, Name, Model, Speed string
}

// Tiers, weakest/fastest first. Speeds are warm generation rates measured on the Vortex server (Oct 25, 2026).
var Tiers = []Tier{
	{"vortex-mini", "Vortex Mini", "7B", "≈14 tok/s · fastest"},
	{"vortex-std", "Vortex", "14B", "≈6 tok/s"},
	{"vortex-pro", "Vortex Pro", "32B coder", "≈3 tok/s · slowest, cold load ≈1.5 min"},
	{"vortex", "Vortex Max", "Mixtral 8x7B (default, always loaded)", "≈8 tok/s"},
}

func defaultComposer() store.Composer { return store.Composer{Tier: "vortex", Length: "normal"} }

func fillComposer(c store.Composer) store.Composer {
	d := defaultComposer()
	if c.Tier == "" {
		c.Tier = d.Tier
	}
	if c.Length == "" {
		c.Length = d.Length
	}
	return c
}

// lengthParams maps the reply-length control and Quick replies to max_tokens and a style hint.
func lengthParams(c store.Composer) (int, string) {
	max, hint := 1024, ""
	switch c.Length {
	case "short":
		max, hint = 200, "Answer briefly: at most a few sentences."
	case "long":
		max, hint = 2048, "Give a thorough, detailed answer."
	}
	if c.Quick {
		if max > 300 {
			max = 300
		}
		if hint != "" {
			hint += " "
		}
		hint += "Reply fast and concisely."
	}
	return max, hint
}
