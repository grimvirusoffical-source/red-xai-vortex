package main

// Desktop strength controls are Vortex-facing model IDs, not llama-server IDs.
// Keep their intended model sizes consistent on macOS, Windows and Linux.
// The gateway checks the caller's permission for the requested Vortex tier
// before selecting its internal model. The tier is never an auth bypass.
func vortexTierTarget(name string) string {
	switch name {
	case "vortex-mini":
		return "qwen2.5-coder-7b"
	case "vortex-std":
		return "qwen2.5-coder-14b"
	case "vortex-pro":
		return "qwen2.5-coder-32b"
	default:
		return ""
	}
}
