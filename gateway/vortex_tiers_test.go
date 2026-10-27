package main

import "testing"

func TestVortexTierModels(t *testing.T) {
	want := map[string]string{
		"vortex-mini": "qwen2.5-coder-7b",
		"vortex-std":  "qwen2.5-coder-14b",
		"vortex-pro":  "qwen2.5-coder-32b",
	}
	for id, target := range want {
		if got := vortexTierTarget(id); got != target {
			t.Errorf("%s routed to %s; want %s", id, got, target)
		}
		if !modelOK(&Key{Models: []string{"vortex"}}, id) {
			t.Errorf("key with Vortex family permission should permit %s", id)
		}
		if !modelOK(&Key{Models: []string{id}}, id) {
			t.Errorf("explicit key permission should permit %s", id)
		}
	}
	for _, id := range []string{"vortex", "vortex-max", "unrelated-model", "vortex-pro-secret"} {
		if got := vortexTierTarget(id); got != "" {
			t.Errorf("unexpected tier route for %s: %s", id, got)
		}
	}
}

func TestVortexTierCannotEscalateRestrictedModels(t *testing.T) {
	miniOnly := &Key{Models: []string{"vortex-mini"}}
	if !modelOK(miniOnly, "vortex-mini") || modelOK(miniOnly, "vortex-pro") {
		t.Fatal("tier-specific permission was not enforced")
	}
	underlyingOnly := &Key{Models: []string{"qwen2.5-coder-7b"}}
	if modelOK(underlyingOnly, "vortex-mini") {
		t.Fatal("a direct model grant must not become a Vortex family grant")
	}
	if modelOK(&Key{Models: []string{"unrelated-model"}}, "vortex-std") {
		t.Fatal("unrelated model key gained a Vortex tier")
	}
}
