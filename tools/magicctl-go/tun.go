package main

const whitelistSentinelUID = 4294967294

func renderTunInbound(s settings, includePkgs, excludePkgs []string) map[string]any {
	tun := map[string]any{
		"type":           "tun",
		"tag":            "tun-in",
		"interface_name": s.Interface,
		"address":        []string{"172.19.0.1/30", "fdfe:dcba:9876::1/126"},
		"mtu":            s.MTU,
		"auto_route":     s.AutoRoute,
		"auto_redirect":  s.AutoRedirect,
		"strict_route":   s.StrictRoute,
		"udp_timeout":    s.UDPTimeout,
		"stack":          s.Stack,
	}
	if s.Stack == "gvisor" && s.EndpointIndependentNAT {
		tun["endpoint_independent_nat"] = true
	}
	if s.PackageMode == "white" {
		tun["include_uid"] = []uint64{whitelistSentinelUID}
		tun["include_package"] = includePkgs
	} else {
		tun["exclude_package"] = excludePkgs
	}
	return tun
}
