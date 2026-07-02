package main

func renderDNS(s settings, _ paths, directDomains []string, ruleSetsUsed bool) map[string]any {
	servers := []any{
		dnsServer(s.DNSLocalType, "local", s.DNSLocalServer, "", s.DNSLocalTLSServerName),
		dnsServer(s.DNSRemoteType, "remote", s.DNSRemoteServer, "proxy", s.DNSRemoteTLSServerName),
	}
	if s.DNSMode == "fake-ip" {
		fakeip := map[string]any{
			"type":        "fakeip",
			"tag":         "fakeip",
			"inet4_range": s.FakeIP4,
		}
		if s.IPv6 {
			fakeip["inet6_range"] = s.FakeIP6
		}
		servers = append(servers, fakeip)
	}

	rules := []any{}
	if s.IPv6Mode != "proxy" {
		rules = append(rules, map[string]any{
			"query_type": []string{"AAAA"},
			"action":     "reject",
		})
	}
	rules = append(rules, map[string]any{
		"domain": directDomains,
		"action": "route",
		"server": "local",
	})
	if ruleSetsUsed {
		rules = append(rules, map[string]any{
			"rule_set": []string{"geosite-cn"},
			"action":   "route",
			"server":   "local",
		})
	}
	rules = append(rules, map[string]any{
		"domain_suffix": []string{"cn"},
		"action":        "route",
		"server":        "local",
	})
	if s.DNSMode == "fake-ip" {
		queryTypes := []string{"A"}
		if s.IPv6 {
			queryTypes = append(queryTypes, "AAAA")
		}
		rules = append(rules, map[string]any{
			"query_type": queryTypes,
			"action":     "route",
			"server":     "fakeip",
		})
	}
	return map[string]any{
		"servers":         servers,
		"reverse_mapping": s.DNSReverseMapping,
		"rules":           rules,
		"final":           s.DNSFinal,
		"strategy":        s.DNSStrategy,
	}
}

func dnsServer(typ, tag, server, detour, tlsName string) map[string]any {
	out := map[string]any{
		"type":   typ,
		"tag":    tag,
		"server": server,
	}
	if detour != "" {
		out["detour"] = detour
	}
	if tlsName != "" && encryptedDNSType(typ) {
		out["tls"] = map[string]any{"server_name": tlsName}
	}
	return out
}

func encryptedDNSType(typ string) bool {
	switch typ {
	case "https", "tls", "quic", "h3":
		return true
	default:
		return false
	}
}
