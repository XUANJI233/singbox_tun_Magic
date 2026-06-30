# AVD sing-box TUN Stack Benchmark, 2026-06-30

## Environment

- Device: `Pixel_9_API_36_1_root` Android emulator, root shell.
- sing-box: `1.13.14`, `android/amd64`, tags include `with_gvisor`.
- Host server: `proxybench-server.exe`, listening on `127.0.0.1:5201`.
- Test target: Android client connects to `198.18.0.10:5201`; sing-box route rule overrides the target address to emulator host `10.0.2.2:5201`.
- Important Android routing detail: manually adding the fake target route to the `main` table is insufficient because root-shell traffic hits Android policy tables such as `wlan0`. The working manual benchmark route used `table wlan0/eth0/main` and an explicit real source address, e.g. `src 10.0.2.16`.

## Stack Results

| stack | check | start | TCP result | conclusion |
|-------|-------|-------|------------|------------|
| `gvisor` | pass | pass | works | reliable in this AVD test |
| `system` | pass | pass | fails with client `dial tcp 198.18.0.10:5201: i/o timeout`; no inbound connection appears in sing-box debug log | not safe as default |
| `mixed` | pass | pass | fails the same way as `system`; this matches its system TCP half | not safe as default |

## gvisor Throughput

| case | total MiB | MiB/s | CPU seconds per MiB | max RSS |
|------|-----------|-------|---------------------|---------|
| single download, 2 runs | 32 | 4.45 avg | 0.262 | 60,780 KiB |
| single upload, 2 runs | 32 | 3.75 avg | 0.100 | 61,548 KiB |
| 4 parallel download | 64 | 7.26 | 0.252 | 65,332 KiB |
| 4 parallel upload | 64 | 3.81 | 0.071 | 67,124 KiB |

## Auto Route Probe

A separate probe used `auto_route: true` with only `route_address: ["198.18.0.10/32"]` to avoid testing only the artificial manual-route setup. `gvisor` produced debug log entries showing the expected route match and outbound connection to `10.0.2.2:5201`. `system` and `mixed` still produced no inbound connection for the TCP client.

## Conclusion

`system` is theoretically attractive because it uses the OS network stack for L3 to L4 translation, and `mixed` would keep gVisor only for UDP. In this module's Android root CLI scenario, both were not usable for TCP in the emulator, while `gvisor` was usable and measurable. Keep `SBMAGIC_STACK=gvisor` as the default. Treat `system` and `mixed` as advanced experimental overrides that require target-device validation before use.
