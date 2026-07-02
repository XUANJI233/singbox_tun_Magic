package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

func renderConfig(p paths) (map[string]any, error) {
	values := defaultSettings()
	if err := mergeEnvFile(values, p.settingsFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err := mergeEnvFile(values, p.apiEnvFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	s, err := parseSettings(values)
	if err != nil {
		return nil, err
	}
	if err := applyIPv6RuntimeState(&s, p.ipv6StateFile); err != nil {
		return nil, err
	}

	outbounds, err := readJSONFile[[]any](p.outboundsFile)
	if err != nil {
		return nil, fmt.Errorf("outbounds: %w", err)
	}

	dnsDirect, err := readListFile(p.dnsDirectFile)
	if err != nil {
		return nil, err
	}
	includePkgs, err := readListFile(p.includeFile)
	if err != nil {
		return nil, err
	}
	excludePkgs, err := readListFile(p.excludeFile)
	if err != nil {
		return nil, err
	}
	proxyPkgs, err := readListFile(p.proxyPackages)
	if err != nil {
		return nil, err
	}
	freeFlowPkgs, err := readListFile(p.freeFlowPackages)
	if err != nil {
		return nil, err
	}

	ruleSetsUsed := s.ProxyRuleMode == "bypass-cn"
	return map[string]any{
		"log": map[string]any{
			"level":     "warn",
			"output":    filepath.Join(p.logDir, "box.log"),
			"timestamp": true,
		},
		"dns":          renderDNS(s, p, dnsDirect, ruleSetsUsed),
		"inbounds":     []any{renderTunInbound(s, includePkgs, excludePkgs)},
		"outbounds":    outbounds,
		"route":        renderRoute(s, p, proxyPkgs, freeFlowPkgs, ruleSetsUsed),
		"experimental": renderExperimental(s, p),
	}, nil
}

func writeRenderedConfig(path string, cfg map[string]any) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Chmod(path, 0o600)
}
