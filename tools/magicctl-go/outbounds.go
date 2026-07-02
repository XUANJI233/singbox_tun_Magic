package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

func prepareOutbounds(s *settings, outbounds []any) ([]any, error) {
	if s.UDPNativeMode == "off" {
		return outbounds, nil
	}
	outbound := findOutboundByTag(outbounds, s.UDPNativeOutbound)
	if outbound == nil {
		return nil, fmt.Errorf("SBMAGIC_UDP_NATIVE_OUTBOUND %q not found in outbounds.json", s.UDPNativeOutbound)
	}
	if isUDPNativeOutbound(outbound) {
		return outbounds, nil
	}
	transport, _ := outbound["transport"].(map[string]any)
	if stringValue(transport["type"]) == "xhttp" && outboundTLSContainsH3(outbound) {
		clone, err := cloneXHTTPH3Outbound(outbounds, outbound)
		if err != nil {
			return nil, err
		}
		s.UDPNativeOutbound = stringValueExact(clone["tag"])
		return append(outbounds, clone), nil
	}
	return nil, fmt.Errorf("SBMAGIC_UDP_NATIVE_OUTBOUND %q is not a UDP-native outbound", s.UDPNativeOutbound)
}

func findOutboundByTag(outbounds []any, tag string) map[string]any {
	if tag == "" {
		return nil
	}
	for _, raw := range outbounds {
		outbound, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if outbound["tag"] != tag {
			continue
		}
		return outbound
	}
	return nil
}

func isUDPNativeOutbound(outbound map[string]any) bool {
	switch stringValue(outbound["type"]) {
	case "hysteria", "hysteria2", "tuic", "wireguard", "tailscale":
		return true
	case "shadowsocks":
		return stringValueExact(outbound["plugin"]) == ""
	case "naive", "trusttunnel":
		return configTruthy(outbound["quic"])
	case "masque":
		return !configTruthy(outbound["use_http2"])
	}
	transport, _ := outbound["transport"].(map[string]any)
	switch stringValue(transport["type"]) {
	case "quic", "kcp":
		return true
	case "xhttp":
		return outboundTLSHasH3(outbound)
	default:
		return false
	}
}

func outboundTLSHasH3(outbound map[string]any) bool {
	alpn := outboundALPNValues(outbound)
	return len(alpn) > 0 && alpn[0] == "h3"
}

func outboundTLSContainsH3(outbound map[string]any) bool {
	for _, value := range outboundALPNValues(outbound) {
		if value == "h3" {
			return true
		}
	}
	return false
}

func cloneXHTTPH3Outbound(outbounds []any, outbound map[string]any) (map[string]any, error) {
	clone, err := cloneOutbound(outbound)
	if err != nil {
		return nil, err
	}
	tag := uniqueInternalOutboundTag(outbounds, stringValueExact(outbound["tag"]))
	clone["tag"] = tag
	tlsOptions, _ := clone["tls"].(map[string]any)
	if tlsOptions == nil {
		tlsOptions = map[string]any{}
		clone["tls"] = tlsOptions
	}
	tlsOptions["alpn"] = []any{"h3"}
	return clone, nil
}

func cloneOutbound(outbound map[string]any) (map[string]any, error) {
	data, err := json.Marshal(outbound)
	if err != nil {
		return nil, err
	}
	var clone map[string]any
	if err := json.Unmarshal(data, &clone); err != nil {
		return nil, err
	}
	return clone, nil
}

func uniqueInternalOutboundTag(outbounds []any, sourceTag string) string {
	base := "__sbmagic_udp_h3_" + sanitizeTag(sourceTag)
	tag := base
	for i := 2; findOutboundByTag(outbounds, tag) != nil; i++ {
		tag = fmt.Sprintf("%s_%d", base, i)
	}
	return tag
}

func sanitizeTag(tag string) string {
	var b strings.Builder
	for _, r := range tag {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-', r == '_', r == '.':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "outbound"
	}
	return b.String()
}

func outboundALPNValues(outbound map[string]any) []string {
	tlsOptions, _ := outbound["tls"].(map[string]any)
	switch alpn := tlsOptions["alpn"].(type) {
	case []any:
		values := make([]string, 0, len(alpn))
		for _, item := range alpn {
			if value := stringValue(item); value != "" {
				values = append(values, value)
			}
		}
		return values
	case string:
		items := strings.Split(alpn, ",")
		values := make([]string, 0, len(items))
		for _, item := range items {
			if value := stringValue(item); value != "" {
				values = append(values, value)
			}
		}
		return values
	}
	return nil
}

func stringValue(value any) string {
	return strings.ToLower(strings.TrimSpace(stringValueExact(value)))
}

func stringValueExact(value any) string {
	if s, ok := value.(string); ok {
		return strings.TrimSpace(s)
	}
	return ""
}

func configTruthy(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case float64:
		return v == 1
	case string:
		switch stringValue(v) {
		case "true", "1", "yes", "on":
			return true
		}
	}
	return false
}
