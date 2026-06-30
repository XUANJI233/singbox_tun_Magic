# AVD proxy benchmark, 2026-06-29

Environment:

- Emulator: `Pixel_9_API_36_1_root`, Android 36.1 Google APIs x86_64, `adb root`
- Host server: `proxybench-server.exe`, listening on `127.0.0.1:5201`
- Android client target:
  - Direct baseline: `10.0.2.2:5201`
  - Proxy tests: `198.18.0.10:5201`, routed to TUN and overridden to `10.0.2.2`
- Per-mode transfer: `16 MiB x 2 runs`
- CPU clock: `CLK_TCK=100`
- Proxy CPU/RSS only; client, server, kernel, and emulator overhead are not included.

## Results

| Route | Mode | Avg MiB/s | Wall s | Proxy CPU ticks | Proxy CPU s | CPU s/MiB | RSS after |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| direct emulator host | download | 5.217 | 6.134 | n/a | n/a | n/a | n/a |
| direct emulator host | upload | 4.361 | 7.338 | n/a | n/a | n/a | n/a |
| sing-box TUN gvisor | download | 5.730 | 5.587 | 748 | 7.48 | 0.234 | 59,100 KiB |
| sing-box TUN gvisor | upload | 4.285 | 7.468 | 300 | 3.00 | 0.094 | 59,356 KiB |
| hev TUN -> sing-box SOCKS | download | 4.652 | 6.884 | 960 | 9.60 | 0.300 | 55,216 KiB |
| hev TUN -> sing-box SOCKS | upload | 3.860 | 8.291 | 213 | 2.13 | 0.067 | 55,216 KiB |

Idle:

| Route | Idle window | Proxy CPU ticks | Proxy CPU s | RSS |
| --- | ---: | ---: | ---: | ---: |
| sing-box TUN gvisor | 20 s | 4 | 0.04 | 56,480 KiB |
| hev TUN -> sing-box SOCKS | 20 s | 2 | 0.02 | 55,216 KiB |

## Interpretation

- Throughput: sing-box native TUN was faster in both directions in this AVD test: about 23% faster for download and 11% faster for upload.
- Proxy CPU under download: sing-box native TUN used less CPU per MiB than hev plus sing-box SOCKS.
- Proxy CPU under upload: hev plus sing-box SOCKS used less CPU per MiB, but it also delivered lower upload throughput.
- Idle cost: both were near zero in a 20-second idle window; the difference is within emulator noise.
- Memory: hev plus sing-box SOCKS used about 4 MiB less RSS than sing-box native TUN after the transfer tests.

Practical conclusion for this architecture: prefer sing-box native TUN when the priority is throughput and mixed/download-heavy efficiency. The hev chain is still viable, especially if SOCKS bridging is required, but it adds another always-running process and was slower overall in this emulator run.
