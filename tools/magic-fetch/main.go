package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sync/atomic"
	"time"
)

const maxBodyBytes = 32 << 20

func main() {
	if len(os.Args) == 3 && os.Args[1] == "--validate-outbounds" {
		if err := validateOutbounds(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	if len(os.Args) < 2 || len(os.Args) > 3 {
		fmt.Fprintln(os.Stderr, "usage: magic-fetch URL [USER_AGENT]")
		fmt.Fprintln(os.Stderr, "       magic-fetch --validate-outbounds FILE")
		os.Exit(2)
	}

	rawURL := os.Args[1]
	ua := "v2rayN/6.42"
	if len(os.Args) == 3 && os.Args[2] != "" {
		ua = os.Args[2]
	}

	u, err := url.Parse(rawURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		fmt.Fprintln(os.Stderr, "invalid http(s) URL")
		os.Exit(2)
	}

	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Accept", "*/*")

	client := &http.Client{
		Timeout: 25 * time.Second,
		Transport: &http.Transport{
			DialContext: dnsDialer().DialContext,
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		fmt.Fprintf(os.Stderr, "HTTP %d\n", resp.StatusCode)
		os.Exit(1)
	}

	limited := &io.LimitedReader{R: resp.Body, N: maxBodyBytes + 1}
	written, err := io.Copy(os.Stdout, limited)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if written > maxBodyBytes {
		fmt.Fprintln(os.Stderr, "response too large")
		os.Exit(1)
	}
}

func dnsDialer() *net.Dialer {
	var next uint32
	servers := []string{"223.5.5.5:53", "1.1.1.1:53"}
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second}
			idx := atomic.AddUint32(&next, 1)
			return d.DialContext(ctx, "udp", servers[int(idx)%len(servers)])
		},
	}
	return &net.Dialer{
		Timeout:  10 * time.Second,
		Resolver: resolver,
	}
}

func validateOutbounds(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	var outbounds []map[string]any
	if err := json.Unmarshal(data, &outbounds); err != nil {
		return fmt.Errorf("invalid JSON for outbounds: %w", err)
	}
	if len(outbounds) == 0 {
		return fmt.Errorf("outbounds must not be empty")
	}

	tags := map[string]bool{}
	for i, outbound := range outbounds {
		tag, _ := outbound["tag"].(string)
		typ, _ := outbound["type"].(string)
		if typ == "" {
			return fmt.Errorf("outbounds[%d] missing type", i)
		}
		if tag == "" {
			return fmt.Errorf("outbounds[%d] missing tag", i)
		}
		if tags[tag] {
			return fmt.Errorf("duplicate outbound tag: %s", tag)
		}
		tags[tag] = true
	}

	for _, required := range []string{"proxy", "direct"} {
		if !tags[required] {
			return fmt.Errorf("required outbound tag missing: %s", required)
		}
	}

	for _, outbound := range outbounds {
		tag, _ := outbound["tag"].(string)
		for _, ref := range stringList(outbound["outbounds"]) {
			if !tags[ref] {
				return fmt.Errorf("outbound[%s] references missing tag: %s", tag, ref)
			}
			if ref == tag {
				return fmt.Errorf("outbound[%s] references itself", tag)
			}
		}
	}

	return nil
}

func stringList(value any) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if s, ok := item.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}
