package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type settings struct {
	Enabled                bool
	SettingsVersion        string
	Stack                  string
	ProcessName            string
	Interface              string
	MTU                    int
	IPv6                   bool
	IPv6Mode               string
	AutoRoute              bool
	AutoRedirect           bool
	TCPCongestionControl   string
	UDPNativeMode          string
	UDPNativeOutbound      string
	StrictRoute            bool
	EndpointIndependentNAT bool
	RejectQUIC             bool
	PackageMode            string
	ProxyRuleMode          string
	FreeFlowRuleMode       string
	MixedRulePriority      string
	DNSMode                string
	DNSStrategy            string
	DNSReverseMapping      bool
	DNSLocalType           string
	DNSLocalServer         string
	DNSLocalTLSServerName  string
	DNSRemoteType          string
	DNSRemoteServer        string
	DNSRemoteTLSServerName string
	DNSFinal               string
	FakeIP4                string
	FakeIP6                string
	APIHost                string
	APIPort                string
	APIMode                string
	APISecret              string
	RulesetDownloadDetour  string
	RuleUpdateInterval     string
	UDPTimeout             string
	Sniff                  bool
	SniffTimeout           string
}

func defaultSettings() map[string]string {
	return map[string]string{
		"SBMAGIC_ENABLED":                    "true",
		"SBMAGIC_SETTINGS_VERSION":           "2",
		"SBMAGIC_STACK":                      "gvisor",
		"SBMAGIC_PROCESS_NAME":               "netd-helper",
		"SBMAGIC_INTERFACE":                  "utun0",
		"SBMAGIC_MTU":                        "9000",
		"SBMAGIC_IPV6":                       "true",
		"SBMAGIC_IPV6_MODE":                  "auto",
		"SBMAGIC_AUTO_ROUTE":                 "true",
		"SBMAGIC_AUTO_REDIRECT":              "true",
		"SBMAGIC_TCP_CONGESTION_CONTROL":     "system",
		"SBMAGIC_UDP_NATIVE_MODE":            "off",
		"SBMAGIC_UDP_NATIVE_OUTBOUND":        "",
		"SBMAGIC_STRICT_ROUTE":               "true",
		"SBMAGIC_ENDPOINT_INDEPENDENT_NAT":   "false",
		"SBMAGIC_REJECT_QUIC":                "false",
		"SBMAGIC_PACKAGE_MODE":               "white",
		"SBMAGIC_PROXY_RULE_MODE":            "bypass-cn",
		"SBMAGIC_FREE_FLOW_RULE_MODE":        "off",
		"SBMAGIC_MIXED_RULE_PRIORITY":        "proxy",
		"SBMAGIC_DNS_MODE":                   "real-ip",
		"SBMAGIC_DNS_STRATEGY":               "ipv4_only",
		"SBMAGIC_DNS_REVERSE_MAPPING":        "true",
		"SBMAGIC_DNS_LOCAL_TYPE":             "udp",
		"SBMAGIC_DNS_LOCAL_SERVER":           "223.5.5.5",
		"SBMAGIC_DNS_LOCAL_TLS_SERVER_NAME":  "",
		"SBMAGIC_DNS_REMOTE_TYPE":            "https",
		"SBMAGIC_DNS_REMOTE_SERVER":          "1.1.1.1",
		"SBMAGIC_DNS_REMOTE_TLS_SERVER_NAME": "cloudflare-dns.com",
		"SBMAGIC_DNS_FINAL":                  "remote",
		"SBMAGIC_FAKEIP4":                    "198.18.0.0/15",
		"SBMAGIC_FAKEIP6":                    "fc00::/18",
		"SBMAGIC_API_HOST":                   "127.0.0.1",
		"SBMAGIC_API_PORT":                   "auto",
		"SBMAGIC_API_MODE":                   "Rule",
		"SBMAGIC_API_SECRET":                 "",
		"SBMAGIC_RULESET_DOWNLOAD_DETOUR":    "direct",
		"SBMAGIC_RULE_UPDATE_INTERVAL":       "168h",
		"SBMAGIC_UDP_TIMEOUT":                "auto",
		"SBMAGIC_SNIFF":                      "false",
		"SBMAGIC_SNIFF_TIMEOUT":              "100ms",
	}
}

func mergeEnvFile(values map[string]string, path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, value, _ := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if !strings.HasPrefix(key, "SBMAGIC_") {
			continue
		}
		values[key] = parseEnvValue(strings.TrimSpace(value))
	}
	return nil
}

func parseEnvValue(value string) string {
	if len(value) >= 2 {
		if value[0] == '\'' && value[len(value)-1] == '\'' {
			return strings.ReplaceAll(value[1:len(value)-1], `'\''`, `'`)
		}
		if value[0] == '"' && value[len(value)-1] == '"' {
			if unquoted, err := strconv.Unquote(value); err == nil {
				return unquoted
			}
		}
	}
	return value
}

func parseSettings(v map[string]string) (settings, error) {
	mtu, err := atoiRange(v["SBMAGIC_MTU"], "SBMAGIC_MTU", 1200, 9000)
	if err != nil {
		return settings{}, err
	}

	boolFor := func(key string) (bool, error) {
		return boolSetting(v[key], key)
	}
	enabled, err := boolFor("SBMAGIC_ENABLED")
	if err != nil {
		return settings{}, err
	}
	ipv6, err := boolFor("SBMAGIC_IPV6")
	if err != nil {
		return settings{}, err
	}
	ipv6Mode := v["SBMAGIC_IPV6_MODE"]
	if ipv6Mode == "" {
		if ipv6 {
			ipv6Mode = "proxy"
		} else {
			ipv6Mode = "block"
		}
	}
	ipv6 = ipv6Mode == "auto" || ipv6Mode == "proxy"
	autoRoute, err := boolFor("SBMAGIC_AUTO_ROUTE")
	if err != nil {
		return settings{}, err
	}
	autoRedirect, err := boolFor("SBMAGIC_AUTO_REDIRECT")
	if err != nil {
		return settings{}, err
	}
	strictRoute, err := boolFor("SBMAGIC_STRICT_ROUTE")
	if err != nil {
		return settings{}, err
	}
	endpointIndependentNAT, err := boolFor("SBMAGIC_ENDPOINT_INDEPENDENT_NAT")
	if err != nil {
		return settings{}, err
	}
	rejectQUIC, err := boolFor("SBMAGIC_REJECT_QUIC")
	if err != nil {
		return settings{}, err
	}
	dnsReverseMapping, err := boolFor("SBMAGIC_DNS_REVERSE_MAPPING")
	if err != nil {
		return settings{}, err
	}
	sniff, err := boolFor("SBMAGIC_SNIFF")
	if err != nil {
		return settings{}, err
	}

	s := settings{
		Enabled:                enabled,
		SettingsVersion:        v["SBMAGIC_SETTINGS_VERSION"],
		Stack:                  v["SBMAGIC_STACK"],
		ProcessName:            v["SBMAGIC_PROCESS_NAME"],
		Interface:              v["SBMAGIC_INTERFACE"],
		MTU:                    mtu,
		IPv6:                   ipv6,
		IPv6Mode:               ipv6Mode,
		AutoRoute:              autoRoute,
		AutoRedirect:           autoRedirect,
		TCPCongestionControl:   v["SBMAGIC_TCP_CONGESTION_CONTROL"],
		UDPNativeMode:          v["SBMAGIC_UDP_NATIVE_MODE"],
		UDPNativeOutbound:      v["SBMAGIC_UDP_NATIVE_OUTBOUND"],
		StrictRoute:            strictRoute,
		EndpointIndependentNAT: endpointIndependentNAT,
		RejectQUIC:             rejectQUIC,
		PackageMode:            v["SBMAGIC_PACKAGE_MODE"],
		ProxyRuleMode:          v["SBMAGIC_PROXY_RULE_MODE"],
		FreeFlowRuleMode:       v["SBMAGIC_FREE_FLOW_RULE_MODE"],
		MixedRulePriority:      v["SBMAGIC_MIXED_RULE_PRIORITY"],
		DNSMode:                v["SBMAGIC_DNS_MODE"],
		DNSStrategy:            v["SBMAGIC_DNS_STRATEGY"],
		DNSReverseMapping:      dnsReverseMapping,
		DNSLocalType:           v["SBMAGIC_DNS_LOCAL_TYPE"],
		DNSLocalServer:         v["SBMAGIC_DNS_LOCAL_SERVER"],
		DNSLocalTLSServerName:  v["SBMAGIC_DNS_LOCAL_TLS_SERVER_NAME"],
		DNSRemoteType:          v["SBMAGIC_DNS_REMOTE_TYPE"],
		DNSRemoteServer:        v["SBMAGIC_DNS_REMOTE_SERVER"],
		DNSRemoteTLSServerName: v["SBMAGIC_DNS_REMOTE_TLS_SERVER_NAME"],
		DNSFinal:               v["SBMAGIC_DNS_FINAL"],
		FakeIP4:                v["SBMAGIC_FAKEIP4"],
		FakeIP6:                v["SBMAGIC_FAKEIP6"],
		APIHost:                v["SBMAGIC_API_HOST"],
		APIPort:                v["SBMAGIC_API_PORT"],
		APIMode:                v["SBMAGIC_API_MODE"],
		APISecret:              v["SBMAGIC_API_SECRET"],
		RulesetDownloadDetour:  v["SBMAGIC_RULESET_DOWNLOAD_DETOUR"],
		RuleUpdateInterval:     v["SBMAGIC_RULE_UPDATE_INTERVAL"],
		UDPTimeout:             effectiveUDPTimeout(v["SBMAGIC_UDP_TIMEOUT"], endpointIndependentNAT, rejectQUIC),
		Sniff:                  sniff,
		SniffTimeout:           v["SBMAGIC_SNIFF_TIMEOUT"],
	}
	if err := validateRenderSettings(s); err != nil {
		return settings{}, err
	}
	return s, nil
}

func effectiveUDPTimeout(value string, endpointIndependentNAT, rejectQUIC bool) string {
	switch value {
	case "", "auto":
		if endpointIndependentNAT {
			return "10m"
		}
		if rejectQUIC {
			return "2m"
		}
		return "5m"
	default:
		return value
	}
}

func boolSetting(value, name string) (bool, error) {
	switch value {
	case "true":
		return true, nil
	case "false", "":
		return false, nil
	default:
		return false, fmt.Errorf("invalid %s %q: use true or false", name, value)
	}
}

func atoiRange(value, name string, min, max int) (int, error) {
	n, err := strconv.Atoi(value)
	if err != nil || n < min || n > max {
		return 0, fmt.Errorf("invalid %s %q: use %d..%d", name, value, min, max)
	}
	return n, nil
}

func validateRenderSettings(s settings) error {
	checkOne := func(value, name string, allowed ...string) error {
		for _, item := range allowed {
			if value == item {
				return nil
			}
		}
		return fmt.Errorf("invalid %s %q: use one of %s", name, value, strings.Join(allowed, ", "))
	}
	if err := checkOne(s.Stack, "SBMAGIC_STACK", "gvisor", "system", "mixed"); err != nil {
		return err
	}
	if err := checkOne(s.TCPCongestionControl, "SBMAGIC_TCP_CONGESTION_CONTROL", "system", "bbr", "cubic", "reno"); err != nil {
		return err
	}
	if err := checkOne(s.UDPNativeMode, "SBMAGIC_UDP_NATIVE_MODE", "off", "quic"); err != nil {
		return err
	}
	if s.UDPNativeMode != "off" && s.UDPNativeOutbound == "" {
		return fmt.Errorf("SBMAGIC_UDP_NATIVE_OUTBOUND is required when SBMAGIC_UDP_NATIVE_MODE=%s", s.UDPNativeMode)
	}
	if err := checkOne(s.IPv6Mode, "SBMAGIC_IPV6_MODE", "auto", "proxy", "block", "off"); err != nil {
		return err
	}
	if err := checkOne(s.PackageMode, "SBMAGIC_PACKAGE_MODE", "black", "white"); err != nil {
		return err
	}
	if err := checkOne(s.ProxyRuleMode, "SBMAGIC_PROXY_RULE_MODE", "off", "global", "bypass-cn"); err != nil {
		return err
	}
	if err := checkOne(s.FreeFlowRuleMode, "SBMAGIC_FREE_FLOW_RULE_MODE", "off", "global"); err != nil {
		return err
	}
	if err := checkOne(s.MixedRulePriority, "SBMAGIC_MIXED_RULE_PRIORITY", "proxy", "free-flow"); err != nil {
		return err
	}
	if err := checkOne(s.DNSMode, "SBMAGIC_DNS_MODE", "real-ip", "fake-ip"); err != nil {
		return err
	}
	if err := checkOne(s.DNSFinal, "SBMAGIC_DNS_FINAL", "remote", "local"); err != nil {
		return err
	}
	if s.IPv6Mode != "proxy" && s.DNSStrategy == "ipv6_only" {
		return fmt.Errorf("SBMAGIC_DNS_STRATEGY=ipv6_only requires SBMAGIC_IPV6_MODE=proxy")
	}
	if s.APIPort == "" || s.APISecret == "" {
		return fmt.Errorf("api.env is missing SBMAGIC_API_PORT or SBMAGIC_API_SECRET")
	}
	return nil
}
