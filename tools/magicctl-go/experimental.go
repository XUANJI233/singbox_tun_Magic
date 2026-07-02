package main

import (
	"net"
	"path/filepath"
)

func renderExperimental(s settings, p paths) map[string]any {
	cacheFile := map[string]any{
		"enabled": true,
		"path":    filepath.Join(p.cacheDir, "cache.db"),
	}
	if s.DNSMode == "fake-ip" {
		cacheFile["store_fakeip"] = true
	}
	return map[string]any{
		"cache_file": cacheFile,
		"clash_api": map[string]any{
			"external_controller": net.JoinHostPort(s.APIHost, s.APIPort),
			"secret":              s.APISecret,
			"default_mode":        s.APIMode,
		},
	}
}
