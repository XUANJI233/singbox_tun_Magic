package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderDefaultSkipsDefaultStrategyPackageLookup(t *testing.T) {
	dir := testDataDir(t, map[string]string{
		"packages.include": "org.example.browser\n",
		"packages.proxy":   "org.example.browser\n",
	})

	cfg, err := renderConfig(newPaths(dir))
	if err != nil {
		t.Fatal(err)
	}
	data := mustJSON(t, cfg)

	if strings.Contains(string(data), `"package_name"`) {
		t.Fatalf("default proxy-priority render should not need package_name lookup:\n%s", data)
	}
	if !strings.Contains(string(data), `"include_uid":[4294967294]`) {
		t.Fatalf("white mode must keep sentinel include_uid:\n%s", data)
	}
	if !strings.Contains(string(data), `"reverse_mapping":true`) {
		t.Fatalf("real-ip mode should keep reverse_mapping enabled:\n%s", data)
	}
}

func TestRejectQUICStaysOnProxyPaths(t *testing.T) {
	dir := testDataDir(t, map[string]string{
		"settings.env": strings.Join([]string{
			"SBMAGIC_REJECT_QUIC=true",
			"SBMAGIC_PROXY_RULE_MODE=off",
			"SBMAGIC_FREE_FLOW_RULE_MODE=global",
			"SBMAGIC_MIXED_RULE_PRIORITY=free-flow",
			"",
		}, "\n"),
	})

	cfg, err := renderConfig(newPaths(dir))
	if err != nil {
		t.Fatal(err)
	}
	route := cfg["route"].(map[string]any)
	rules := route["rules"].([]any)

	unscopedRejects := 0
	for _, raw := range rules {
		rule := raw.(map[string]any)
		if rule["action"] == "reject" && rule["network"] == "udp" {
			if _, ok := rule["clash_mode"]; !ok {
				unscopedRejects++
			}
		}
	}
	if unscopedRejects != 0 {
		t.Fatalf("reject_quic must not block UDP/443 outside proxy paths when proxy mode is off: %#v", rules)
	}
}

func TestFakeIPIPv6Render(t *testing.T) {
	dir := testDataDir(t, map[string]string{
		"settings.env": strings.Join([]string{
			"SBMAGIC_DNS_MODE=fake-ip",
			"SBMAGIC_IPV6=true",
			"SBMAGIC_DNS_STRATEGY=prefer_ipv4",
			"",
		}, "\n"),
	})

	cfg, err := renderConfig(newPaths(dir))
	if err != nil {
		t.Fatal(err)
	}
	data := mustJSON(t, cfg)
	for _, want := range []string{`"tag":"fakeip"`, `"inet6_range":"fc00::/18"`, `"store_fakeip":true`} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("missing %s in fake-ip render:\n%s", want, data)
		}
	}
	if strings.Contains(string(data), `"query_type":["AAAA"]`) && strings.Contains(string(data), `"action":"reject"`) {
		t.Fatalf("IPv6 enabled render should not reject AAAA:\n%s", data)
	}
}

func testDataDir(t *testing.T, overrides map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for _, sub := range []string{"configs", "runtime", "cache/rulesets", "logs"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			t.Fatal(err)
		}
	}

	files := map[string]string{
		"settings.env":                     "",
		"outbounds.json":                   `[{"type":"selector","tag":"proxy","outbounds":["node","direct"]},{"type":"vless","tag":"node","server":"example.com","server_port":443,"uuid":"00000000-0000-0000-0000-000000000000"},{"type":"direct","tag":"direct"},{"type":"direct","tag":"free-flow"}]`,
		"packages.exclude":                 "",
		"packages.include":                 "",
		"packages.proxy":                   "",
		"packages.free-flow":               "",
		"dns-direct-domains.txt":           "connectivitycheck.gstatic.com\nclients3.google.com\n",
		"../runtime/api.env":               "SBMAGIC_API_SECRET=testsecret\nSBMAGIC_API_PORT=25000\n",
		"../cache/rulesets/cn.srs":         "unused",
		"../cache/rulesets/geosite-cn.srs": "x",
		"../cache/rulesets/geoip-cn.srs":   "x",
	}
	for name, value := range overrides {
		files[name] = value
	}
	for name, value := range files {
		path := filepath.Join(dir, "configs", name)
		if strings.HasPrefix(name, "../") {
			path = filepath.Join(dir, strings.TrimPrefix(name, "../"))
		}
		if err := os.WriteFile(path, []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
