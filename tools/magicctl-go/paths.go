package main

import (
	"os"
	"path/filepath"
)

type paths struct {
	dataDir          string
	configDir        string
	runtimeDir       string
	logDir           string
	cacheDir         string
	rulesetDir       string
	settingsFile     string
	apiEnvFile       string
	outboundsFile    string
	excludeFile      string
	includeFile      string
	proxyPackages    string
	freeFlowPackages string
	dnsDirectFile    string
	geositeCN        string
	geoipCN          string
	configFile       string
}

func defaultDataDir() string {
	if v := os.Getenv("SBMAGIC_DATA_DIR"); v != "" {
		return v
	}
	return "/data/adb/singbox_tun_Magic"
}

func newPaths(dataDir string) paths {
	configDir := filepath.Join(dataDir, "configs")
	runtimeDir := filepath.Join(dataDir, "runtime")
	cacheDir := filepath.Join(dataDir, "cache")
	rulesetDir := filepath.Join(cacheDir, "rulesets")
	return paths{
		dataDir:          dataDir,
		configDir:        configDir,
		runtimeDir:       runtimeDir,
		logDir:           filepath.Join(dataDir, "logs"),
		cacheDir:         cacheDir,
		rulesetDir:       rulesetDir,
		settingsFile:     filepath.Join(configDir, "settings.env"),
		apiEnvFile:       filepath.Join(runtimeDir, "api.env"),
		outboundsFile:    filepath.Join(configDir, "outbounds.json"),
		excludeFile:      filepath.Join(configDir, "packages.exclude"),
		includeFile:      filepath.Join(configDir, "packages.include"),
		proxyPackages:    filepath.Join(configDir, "packages.proxy"),
		freeFlowPackages: filepath.Join(configDir, "packages.free-flow"),
		dnsDirectFile:    filepath.Join(configDir, "dns-direct-domains.txt"),
		geositeCN:        filepath.Join(rulesetDir, "geosite-cn.srs"),
		geoipCN:          filepath.Join(rulesetDir, "geoip-cn.srs"),
		configFile:       filepath.Join(runtimeDir, "config.json"),
	}
}
