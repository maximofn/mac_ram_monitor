# Mac RAM Monitor

🍎 RAM monitor for macOS, surfaced in the menu bar. Live used / available / swap stats and the top processes by RSS, all from a tiny menubar icon. Same wire-format as the [Linux ram_monitor](https://github.com/maximofn/ram_monitor) so a single Home Assistant package or LAN client works against either backend.

## Architecture

Two halves, one wire format:

- **Rust backend** (`crates/`) — `mac-ram-monitord`: HTTP+SSE daemon that wraps `sysinfo` for memory totals, swap, and per-process RSS/VSZ. Defaults to `127.0.0.1:9135`. Cheap (~few MB RSS, ~0% CPU at 1 Hz).
- **Swift frontend** (`front-mac/`) — `mac-ram-monitor-tray`: AppKit menubar app, no third-party deps. Consumes `/v1/stream` and renders into `NSStatusItem` via CoreGraphics.

Why split it: the daemon stays headless and can be tunnelled over SSH from another Mac/Linux box. The Swift tray just points at whatever URL has the data.

Sister projects (each one is its own repo so you can install only what your machine needs): `mac_cpu_monitor`, `mac_gpu_monitor`, `mac_disk_monitor`. Default ports: gpu=9133, cpu=9134, **ram=9135**, disk=9136. Linux equivalents live on 9123-9126.

## Install

### Build

```bash
git clone https://github.com/maximofn/mac_ram_monitor.git
cd mac_ram_monitor
cargo build --release --workspace
cd front-mac && ./scripts/build-app.sh
```

This produces:

- `target/release/mac-ram-monitord` — the backend binary.
- `front-mac/build/Mac RAM Monitor.app` — the menubar app bundle.

### Run

```bash
./target/release/mac-ram-monitord --port 9135 &
open "front-mac/build/Mac RAM Monitor.app"
```

Sanity check:

```bash
curl -s http://127.0.0.1:9135/v1/info
curl -s http://127.0.0.1:9135/v1/snapshot | jq
```

### Autostart on login

Two LaunchAgents — one for the daemon, one for the tray:

```bash
cd front-mac
./scripts/install-daemon.sh        # runs mac-ram-monitord on login (KeepAlive)
./scripts/install-launchagent.sh   # runs the tray app on login
```

Logs land in `~/Library/Logs/mac-ram-monitord.{out,err}.log` and `~/Library/Logs/mac-ram-monitor-tray.{out,err}.log`.

To uninstall:

```bash
./scripts/install-daemon.sh uninstall
./scripts/install-launchagent.sh uninstall
```

## CLI flags

```bash
mac-ram-monitord --help
# --bind, --port, --sample-interval-ms, --top-processes, --log-level

mac-ram-monitor-tray --help
# --backend-url, --icon-height, --dump-icon (debug: render one PNG and exit), --log-level
```

## API (HTTP)

The daemon serves snapshots over plain HTTP and SSE, defaulting to `127.0.0.1:9135` (no auth — bind LAN only behind a reverse proxy or use SSH port forwarding).

| Method | Path             | Description                                |
|--------|------------------|--------------------------------------------|
| GET    | `/healthz`       | Liveness + uptime                          |
| GET    | `/v1/info`       | Backend version, host, kernel, total RAM   |
| GET    | `/v1/snapshot`   | Full snapshot (memory + swap + processes)  |
| GET    | `/v1/memory`     | Memory totals only                         |
| GET    | `/v1/swap`       | Swap totals only                           |
| GET    | `/v1/processes`  | Top-N processes by RSS                     |
| GET    | `/v1/stream`     | SSE stream of `Snapshot` events            |

The schema is identical to the Linux `ram_monitor` daemon, except `buffers_bytes` and `cached_bytes` always serialise as `0` on macOS — Darwin's unified buffer cache doesn't separate them out, and `available_bytes` already accounts for reclaimable file-backed memory.

## Consuming a Linux ram-monitord from this Mac

```bash
ssh -fN -L 9125:127.0.0.1:9125 <ubuntu-host>
open "front-mac/build/Mac RAM Monitor.app" --args --backend-url http://127.0.0.1:9125
```

## Requirements

- macOS 13 or later (the menubar app uses Swift Concurrency).
- Apple Silicon or Intel — the backend is sysinfo-only, no `macmon` dependency.
- Rust toolchain ≥ 1.85 (`rustup`, see `rust-toolchain.toml`).

## Support

Consider giving a **☆ Star** to this repository, or invite me to a coffee:

[![BuyMeACoffee](https://img.shields.io/badge/Buy_Me_A_Coffee-support_my_work-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white&labelColor=101010)](https://www.buymeacoffee.com/maximofn)
