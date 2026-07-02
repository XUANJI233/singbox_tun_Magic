package main

import (
	"errors"
	"os"
	"strings"
)

func applyIPv6RuntimeState(s *settings, stateFile string) error {
	if s.IPv6Mode != "auto" {
		return nil
	}
	values, err := readSimpleKeyValueFile(stateFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			s.IPv6 = false
			s.IPv6Mode = "block"
			s.DNSStrategy = "ipv4_only"
			return nil
		}
		return err
	}
	switch values["effective_mode"] {
	case "block":
		s.IPv6 = false
		s.IPv6Mode = "block"
		s.DNSStrategy = "ipv4_only"
	case "off":
		s.IPv6 = false
		s.IPv6Mode = "off"
		s.DNSStrategy = "ipv4_only"
	case "proxy":
		s.IPv6 = true
		s.IPv6Mode = "proxy"
	case "":
		s.IPv6 = false
		s.IPv6Mode = "block"
		s.DNSStrategy = "ipv4_only"
	default:
		s.IPv6 = false
		s.IPv6Mode = "block"
		s.DNSStrategy = "ipv4_only"
	}
	return nil
}

func readSimpleKeyValueFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	values := map[string]string{}
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, value, _ := strings.Cut(line, "=")
		values[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return values, nil
}
