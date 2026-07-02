package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "render":
		if err := renderCmd(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "ERROR:", err)
			os.Exit(1)
		}
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: magicctl-go render --data-dir DIR [--output FILE]")
}

func renderCmd(args []string) error {
	fs := flag.NewFlagSet("render", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	dataDir := fs.String("data-dir", defaultDataDir(), "module data directory")
	output := fs.String("output", "", "rendered config path")
	if err := fs.Parse(args); err != nil {
		return err
	}

	p := newPaths(*dataDir)
	if *output != "" {
		p.configFile = *output
	}

	cfg, err := renderConfig(p)
	if err != nil {
		return err
	}
	if err := writeRenderedConfig(p.configFile, cfg); err != nil {
		return err
	}
	fmt.Println(p.configFile)
	return nil
}
