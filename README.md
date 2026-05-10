# Mac RAM Monitor

<p align="center">
  <img src="assets/ram.png" width="160" alt="Mac RAM Monitor icon"/>
</p>

Real-time RAM monitor for macOS. Split into a small backend daemon that samples `host_statistics64()` + `vm.swapusage` (via [`sysinfo`](https://crates.io/crates/sysinfo)) and exposes an HTTP/SSE API, plus a native Swift menubar frontend that renders an icon (RAM-chip silhouette + used-GiB label + used-% donut) into `NSStatusItem`.

Same on-the-wire schema as the Linux [`ram_monitor`](https://github.com/maximofn/ram_monitor) sibling, just a different backend and a different port — both can run side by side on the same Mac.

## Architecture

```
+-------------------------+        HTTP/SSE         +----------------------------+
|   mac-ram-monitord      | <---------------------- |   Mac RAM Monitor.app      |
|       (sysinfo)         |    /v1/stream JSON      |  (NSStatusItem + AppKit)   |
+-------------------------+                         +----------------------------+
        ^                                                       ^
        | host_statistics64() / vm.swapusage / proc_pidinfo     | NSStatusBar
        v                                                       v
   XNU kernel                                              macOS menu bar
```

The Rust binaries live in a single Cargo workspace under `crates/`:

- `mac-ram-monitor-core` — shared `Snapshot` / `Memory` / `Swap` / `Process` types serialised with `serde`. Identical to the Linux backend's schema so external consumers (Home Assistant, dashboards, etc.) work against either backend unchanged.
- `mac-ram-monitord` — backend daemon. Uses `sysinfo` for memory totals (`total / free / available / used`), swap totals, and per-process RSS / VSZ / memory %. Defaults to `127.0.0.1:9135`.

The macOS frontend lives in `front-mac/` as a Swift Package (Swift + AppKit + CoreGraphics, zero third-party deps). It consumes `/v1/stream` and renders into the menubar via `NSStatusItem`. The donut shows used %, the side label is the used memory in GiB (the figure Activity Monitor surfaces as "Memory Used").

## Requirements

- macOS 13 or later (the Swift package targets `.macOS(.v13)`).
- Apple Silicon (`arm64`) or Intel (`x86_64`) — the backend is `sysinfo`-only, so no architecture-specific dependencies.
- **Rust toolchain ≥ 1.85** (stable). Install via [rustup](https://rustup.rs):
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source "$HOME/.cargo/env"
  ```
- **Swift 5.9+** (Xcode Command Line Tools): `xcode-select --install`.

No `sudo` is required at runtime: `sysinfo` reads the Mach host port and `proc_pidinfo` in user space.

## Build

```bash
# Backend
cargo build --release --workspace
# → target/release/mac-ram-monitord

# Frontend
cd front-mac
./scripts/build-app.sh
# → front-mac/build/Mac RAM Monitor.app
```

## Run

In two terminals (or as services — see Autostart below):

```bash
./target/release/mac-ram-monitord --bind 127.0.0.1 --port 9135
open "front-mac/build/Mac RAM Monitor.app"
```

Or pass a custom backend URL explicitly:

```bash
"front-mac/build/Mac RAM Monitor.app/Contents/MacOS/mac-ram-monitor-tray" \
    --backend-url http://127.0.0.1:9135
```

### Daemon flags

| Flag | Default | Purpose |
|---|---|---|
| `--bind` | `127.0.0.1` | bind address (no auth, keep loopback) |
| `--port` | `9135` | HTTP port. Mac variants use the 9133-9136 band; Linux uses 9123-9126 — both can run side by side (e.g. with an SSH tunnel from a remote Linux host) |
| `--sample-interval-ms` | `1000` | sampler period |
| `--top-processes` | `5` | top-N memory consumers per snapshot (`0` disables) |
| `--log-level` | `info` | also via `RUST_LOG` |

### Tray flags

`--backend-url`, `--icon-height`, `--dump-icon <path>` (renders one snapshot to PNG and exits — useful to inspect what the menubar receives without fighting AppKit), `--version`, `-h`.

### Quick API smoke test

```bash
curl -s http://127.0.0.1:9135/v1/snapshot | jq
curl -N http://127.0.0.1:9135/v1/stream         # SSE: one event per second
```

## API

| Endpoint | Purpose |
|---|---|
| `GET /healthz` | liveness |
| `GET /v1/info` | backend / kernel / total RAM metadata |
| `GET /v1/snapshot` | full latest snapshot (memory + swap + processes) |
| `GET /v1/memory` | just the `memory` object (total / free / available / used / buffers / cached) |
| `GET /v1/swap` | just the `swap` object |
| `GET /v1/processes` | top processes by RSS |
| `GET /v1/stream` | SSE — one snapshot per event |

## Autostart on login

Two LaunchAgents live in `front-mac/scripts/`. Run from `front-mac/`:

```bash
./scripts/install-daemon.sh         # backend on login (port 9135, KeepAlive)
./scripts/install-launchagent.sh    # tray autostart on login
```

Logs land in `~/Library/Logs/mac-ram-monitord.{out,err}.log` and `~/Library/Logs/mac-ram-monitor-tray.{out,err}.log`. Pass `uninstall` to either script to remove its agent.

## Notes on the data sources

- **Total / free / available memory** come from `sysinfo`, which on macOS wraps `host_statistics64(HOST_VM_INFO64)`. `available_memory` corresponds to free + speculative + inactive (purgeable) — the closest match to Linux's `MemAvailable` in `/proc/meminfo`. Used follows the Linux convention: `used = total − available`.
- **`buffers_bytes` and `cached_bytes`** are kept in the wire schema for parity with the Linux sibling but always serialise as `0` on macOS. Darwin's unified buffer cache doesn't separate them out the way `/proc/meminfo` does — those reclaimable pages are already accounted for in `available_bytes`.
- **Swap** comes from `sysctl vm.swapusage`, exposed by `sysinfo` as `total_swap` / `free_swap`.
- **Per-process RSS / VSZ** come from `proc_pidinfo(PROC_PIDTASKINFO)` via `sysinfo::Process::memory()` and `virtual_memory()`. Sorted by RSS desc, ties broken by PID asc — same ordering as the Linux daemon, so the Home Assistant "top process" attribute stays stable across backends.

## Sister projects

Each one is its own repo so you can install only what your machine needs. Default ports:

| Resource | Linux | Mac |
|---|---|---|
| GPU | 9123 | 9133 |
| CPU | 9124 | [9134](https://github.com/maximofn/mac_cpu_monitor) |
| **RAM** | [9125](https://github.com/maximofn/ram_monitor) | **9135** (this repo) |
| Disk | 9126 | 9136 |

## Support

If this is useful to you, consider giving a **☆ Star** to the repo, or invite me to a coffee:

[![BuyMeACoffee](https://img.shields.io/badge/Buy_Me_A_Coffee-support_my_work-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white&labelColor=101010)](https://www.buymeacoffee.com/maximofn)

## License

MIT — see `LICENSE`.
