package main

func renderRoute(s settings, p paths, proxyPkgs, freeFlowPkgs []string, ruleSetsUsed bool) map[string]any {
	rules := []any{
		map[string]any{"protocol": "dns", "action": "hijack-dns"},
	}
	if s.Sniff {
		rules = append(rules, map[string]any{"action": "sniff", "timeout": s.SniffTimeout})
	}
	if s.IPv6Mode == "block" {
		rules = append(rules, map[string]any{"ip_version": 6, "action": "reject"})
	}
	rules = append(rules,
		map[string]any{"ip_is_private": true, "outbound": "direct"},
		map[string]any{"clash_mode": "Direct", "outbound": "direct"},
	)
	if s.UDPNativeMode == "quic" {
		rules = append(rules, clashGlobalUDPNativeRule(s))
	} else if s.RejectQUIC {
		rules = append(rules, clashGlobalQUICRejectRule())
	}
	rules = append(rules, map[string]any{"clash_mode": "Global", "outbound": "proxy"})

	effectiveProxyPkgs := proxyPkgs
	if s.MixedRulePriority == "proxy" {
		effectiveProxyPkgs = nil
	}
	effectiveFreeFlowPkgs := freeFlowPkgs
	if s.MixedRulePriority == "free-flow" {
		effectiveFreeFlowPkgs = nil
	}
	rules = append(rules, proxyRules(s, effectiveProxyPkgs, true)...)
	rules = append(rules, freeFlowRules(s, effectiveFreeFlowPkgs, true)...)
	if s.MixedRulePriority == "free-flow" {
		rules = append(rules, freeFlowRules(s, nil, false)...)
		rules = append(rules, proxyRules(s, nil, false)...)
	} else {
		rules = append(rules, proxyRules(s, nil, false)...)
		rules = append(rules, freeFlowRules(s, nil, false)...)
	}

	route := map[string]any{
		"rules":                 rules,
		"final":                 "direct",
		"auto_detect_interface": true,
		"default_domain_resolver": map[string]any{
			"server": "local",
		},
	}
	if ruleSetsUsed {
		route["rule_set"] = routeRuleSets(s, p)
	}
	return route
}

func proxyRules(s settings, packages []string, scoped bool) []any {
	if scoped && len(packages) == 0 {
		return nil
	}
	pkg := packageRuleField(packages, scoped)
	switch s.ProxyRuleMode {
	case "off":
		return nil
	case "global":
		rules := []any{}
		if s.UDPNativeMode == "quic" {
			rules = append(rules, udpNativeQUICRule(s, pkg))
		} else if s.RejectQUIC {
			rules = append(rules, quicRejectRule(pkg))
		}
		rules = append(rules, mergeRule(map[string]any{"outbound": "proxy"}, pkg))
		return rules
	case "bypass-cn":
		rules := []any{
			mergeRule(map[string]any{
				"domain_suffix": []string{"cn"},
				"outbound":      "direct",
			}, pkg),
			mergeRule(map[string]any{
				"rule_set": []string{"geosite-cn", "geoip-cn"},
				"outbound": "direct",
			}, pkg),
		}
		if s.UDPNativeMode == "quic" {
			rules = append(rules, udpNativeQUICRule(s, pkg))
		} else if s.RejectQUIC {
			rules = append(rules, quicRejectRule(pkg))
		}
		rules = append(rules, mergeRule(map[string]any{"outbound": "proxy"}, pkg))
		return rules
	default:
		return nil
	}
}

func freeFlowRules(s settings, packages []string, scoped bool) []any {
	if scoped && len(packages) == 0 {
		return nil
	}
	if s.FreeFlowRuleMode != "global" {
		return nil
	}
	return []any{mergeRule(map[string]any{"outbound": "free-flow"}, packageRuleField(packages, scoped))}
}

func packageRuleField(packages []string, scoped bool) map[string]any {
	if !scoped {
		return nil
	}
	return map[string]any{"package_name": packages}
}

func mergeRule(base, extra map[string]any) map[string]any {
	out := make(map[string]any, len(base)+len(extra))
	for k, v := range base {
		out[k] = v
	}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

func quicRejectRule(extra map[string]any) map[string]any {
	return mergeRule(map[string]any{
		"network": "udp",
		"port":    []int{443},
		"action":  "reject",
	}, extra)
}

func udpNativeQUICRule(s settings, extra map[string]any) map[string]any {
	return mergeRule(map[string]any{
		"network":  "udp",
		"port":     []int{443},
		"outbound": s.UDPNativeOutbound,
	}, extra)
}

func clashGlobalQUICRejectRule() map[string]any {
	return mergeRule(quicRejectRule(nil), map[string]any{"clash_mode": "Global"})
}

func clashGlobalUDPNativeRule(s settings) map[string]any {
	return mergeRule(udpNativeQUICRule(s, nil), map[string]any{"clash_mode": "Global"})
}

func routeRuleSets(s settings, p paths) []any {
	if fileHasContent(p.geositeCN) && fileHasContent(p.geoipCN) {
		return []any{
			map[string]any{"tag": "geosite-cn", "type": "local", "format": "binary", "path": p.geositeCN},
			map[string]any{"tag": "geoip-cn", "type": "local", "format": "binary", "path": p.geoipCN},
		}
	}
	return []any{
		map[string]any{
			"tag":             "geosite-cn",
			"type":            "remote",
			"format":          "binary",
			"url":             "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
			"download_detour": s.RulesetDownloadDetour,
			"update_interval": s.RuleUpdateInterval,
		},
		map[string]any{
			"tag":             "geoip-cn",
			"type":            "remote",
			"format":          "binary",
			"url":             "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs",
			"download_detour": s.RulesetDownloadDetour,
			"update_interval": s.RuleUpdateInterval,
		},
	}
}
