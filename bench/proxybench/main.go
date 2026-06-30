package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type result struct {
	Mode     string  `json:"mode"`
	Bytes    int64   `json:"bytes"`
	Parallel int     `json:"parallel"`
	Seconds  float64 `json:"seconds"`
	MiBps    float64 `json:"mibps"`
}

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: proxybench server|client ...")
	}
	switch os.Args[1] {
	case "server":
		server(os.Args[2:])
	case "client":
		client(os.Args[2:])
	default:
		log.Fatalf("unknown mode %q", os.Args[1])
	}
}

func server(args []string) {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	listenAddr := fs.String("listen", "127.0.0.1:5201", "listen address")
	_ = fs.Parse(args)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("proxybench server listening on %s", *listenAddr)
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Print(err)
			continue
		}
		go handleConn(conn)
	}
}

func handleConn(conn net.Conn) {
	defer conn.Close()
	br := bufio.NewReader(conn)
	line, err := br.ReadString('\n')
	if err != nil {
		return
	}
	fields := strings.Fields(line)
	if len(fields) != 2 {
		return
	}
	n, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil || n < 0 {
		return
	}
	switch fields[0] {
	case "U":
		_, _ = io.CopyN(io.Discard, br, n)
		_, _ = conn.Write([]byte("OK\n"))
	case "D":
		_, _ = io.CopyN(conn, zeroReader{}, n)
	default:
		return
	}
}

type zeroReader struct{}

func (zeroReader) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 0
	}
	return len(p), nil
}

func client(args []string) {
	fs := flag.NewFlagSet("client", flag.ExitOnError)
	target := fs.String("target", "198.18.0.10:5201", "target address")
	mode := fs.String("mode", "download", "download or upload")
	sizeMiB := fs.Int64("mib", 64, "transfer size in MiB")
	runs := fs.Int("runs", 3, "runs")
	parallel := fs.Int("parallel", 1, "parallel connections; each transfers -mib MiB")
	_ = fs.Parse(args)

	bytes := *sizeMiB * 1024 * 1024
	enc := json.NewEncoder(os.Stdout)
	for i := 0; i < *runs; i++ {
		r, err := runParallel(*target, *mode, bytes, *parallel)
		if err != nil {
			log.Fatal(err)
		}
		_ = enc.Encode(r)
		time.Sleep(500 * time.Millisecond)
	}
}

func runParallel(target, mode string, bytesPerConn int64, parallel int) (result, error) {
	if parallel < 1 {
		return result{}, fmt.Errorf("parallel must be positive")
	}
	start := make(chan struct{})
	errs := make(chan error, parallel)
	var wg sync.WaitGroup
	wg.Add(parallel)
	for i := 0; i < parallel; i++ {
		go func() {
			defer wg.Done()
			<-start
			errs <- transferOnce(target, mode, bytesPerConn)
		}()
	}
	begin := time.Now()
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			return result{}, err
		}
	}
	seconds := time.Since(begin).Seconds()
	totalBytes := bytesPerConn * int64(parallel)
	return result{
		Mode:     mode,
		Bytes:    totalBytes,
		Parallel: parallel,
		Seconds:  seconds,
		MiBps:    float64(totalBytes) / 1024 / 1024 / seconds,
	}, nil
}

func transferOnce(target, mode string, bytes int64) error {
	conn, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()

	var cmd string
	switch mode {
	case "upload":
		cmd = "U"
	case "download":
		cmd = "D"
	default:
		return fmt.Errorf("unknown client mode %q", mode)
	}

	if _, err := fmt.Fprintf(conn, "%s %d\n", cmd, bytes); err != nil {
		return err
	}
	if mode == "upload" {
		if _, err := io.CopyN(conn, zeroReader{}, bytes); err != nil {
			return err
		}
		_, _ = bufio.NewReader(conn).ReadString('\n')
	} else {
		if _, err := io.CopyN(io.Discard, conn, bytes); err != nil {
			return err
		}
	}
	return nil
}
