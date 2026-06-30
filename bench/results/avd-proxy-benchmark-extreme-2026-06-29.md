# AVD proxy benchmark, extreme rerun, 2026-06-29

Environment:

- Emulator: `Pixel_9_API_36_1_root`, Android 36.1 Google APIs x86_64, `adb root`
- Host server: `proxybench-server.exe`, listening on `127.0.0.1:5201`
- Android client target:
  - Direct baseline: `10.0.2.2:5201`
  - Proxy tests: `198.18.0.10:5201`, routed to TUN and overridden to `10.0.2.2`
- CPU clock: `CLK_TCK=100`
- Proxy CPU/RSS only; client, server, kernel, and emulator overhead are not included.

## Throughput And Proxy CPU

| Route | Scenario | MiB total | MiB/s | Proxy CPU ticks | Proxy CPU s | CPU s/MiB | RSS after |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| direct emulator host | single download | 128 | 6.711 | n/a | n/a | n/a | n/a |
| direct emulator host | single upload | 128 | 4.947 | n/a | n/a | n/a | n/a |
| direct emulator host | par4 download | 256 | 7.069 | n/a | n/a | n/a | n/a |
| direct emulator host | par4 upload | 256 | 4.925 | n/a | n/a | n/a | n/a |
| sing-box TUN gvisor | single download | 128 | 5.293 | 3,348 | 33.48 | 0.262 | 62,192 KiB |
| sing-box TUN gvisor | single upload | 128 | 3.758 | 1,138 | 11.38 | 0.089 | 62,468 KiB |
| sing-box TUN gvisor | par4 download | 256 | 7.956 | 6,254 | 62.54 | 0.244 | 72,752 KiB |
| sing-box TUN gvisor | par4 upload | 256 | 3.876 | 1,874 | 18.74 | 0.073 | 72,880 KiB |
| hev TUN -> sing-box SOCKS | single download | 128 | 5.395 | 3,878 | 38.78 | 0.303 | 57,148 KiB |
| hev TUN -> sing-box SOCKS | single upload | 128 | 3.927 | 1,005 | 10.05 | 0.079 | 57,148 KiB |
| hev TUN -> sing-box SOCKS | par4 download | 256 | 5.354 | 7,516 | 75.16 | 0.294 | 57,860 KiB |
| hev TUN -> sing-box SOCKS | par4 upload | 256 | 3.759 | 1,553 | 15.53 | 0.061 | 57,988 KiB |

Idle:

| Route | Idle window | Proxy CPU ticks | Proxy CPU s | RSS |
| --- | ---: | ---: | ---: | ---: |
| sing-box TUN gvisor | 20 s | 2 | 0.02 | 51,944 KiB |
| hev TUN -> sing-box SOCKS | 20 s | 3 | 0.03 | 56,520 KiB |

## Interpretation

- The first run was not pure noise: under 4-connection download pressure, sing-box native TUN was much faster and used less proxy CPU per MiB.
- Single-connection large transfer is closer: hev slightly beat sing-box in throughput for this one run, but download CPU cost was still higher.
- Upload favors hev on proxy CPU per MiB in both runs, though 4-connection upload throughput was still slightly lower than sing-box.
- Memory flipped compared with the smaller run at peak pressure: sing-box native TUN rose to about 72.9 MiB RSS, while hev plus sing-box SOCKS stayed around 58.0 MiB RSS.

Practical conclusion after the rerun: if the target workload is download-heavy or concurrent, sing-box native TUN is the better default. If the workload is mostly upload and low concurrency, hev plus SOCKS can be competitive and uses less proxy CPU, but it is not a clear overall efficiency win once concurrency is added.
