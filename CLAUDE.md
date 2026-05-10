# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project layout

Two halves living side by side, sharing nothing at runtime except the JSON wire-format:

- **Rust backend** in `crates/` (Cargo workspace): `mac-ram-monitor-core` (shared serde types) + `mac-ram-monitord` (HTTP/SSE daemon, default `127.0.0.1:9135`).
- **Swift frontend** in `front-mac/` (Swift Package, AppKit, no third-party deps): a menubar-only app (`LSUIElement`) that consumes the daemon's `/v1/stream`.

The on-the-wire schema (`crates/mac-ram-monitor-core/src/model.rs` ↔ `front-mac/Sources/MacRAMMonitorTray/Models.swift`) is intentionally identical to the Linux sibling at `../ram_monitor`. **If you add or rename a field on the Rust side, mirror it in `Models.swift` (with the matching `CodingKeys`) or the JSON decode silently drops it.**

## Common commands

Rust requires `rustup` (≥ 1.85, edition 2024 deps). It was installed with `--no-modify-path`, so prefix Rust commands with `. "$HOME/.cargo/env"` if `cargo` isn't already on `PATH`.

```bash
# Rust (run from repo root)
cargo build --workspace                 # debug
cargo build --release --workspace       # release → target/release/mac-ram-monitord
cargo test --workspace                  # core has a JSON-roundtrip test
cargo clippy --workspace --all-targets
cargo test -p mac-ram-monitor-core model::tests::snapshot_roundtrips_through_json

# Swift (run from front-mac/)
./scripts/build-app.sh                  # → build/Mac RAM Monitor.app
swift build -c release --arch arm64     # raw binary only, no .app wrapper

# End-to-end
./target/release/mac-ram-monitord --port 9135 &
open "front-mac/build/Mac RAM Monitor.app"
curl -s http://127.0.0.1:9135/v1/snapshot | jq
curl -N http://127.0.0.1:9135/v1/stream      # SSE, one event per second
"front-mac/build/Mac RAM Monitor.app/Contents/MacOS/mac-ram-monitor-tray" --dump-icon /tmp/icon.png
```

## Architecture notes that span files

### Sampling thread model (Rust)

`crates/mac-ram-monitord/src/sampler.rs::spawn_sampler` runs on a **dedicated `std::thread`**. The RAM sample call itself is fast (sysinfo-only, no IOReport blocking like the CPU sibling) so a tokio task would also work, but keeping the same thread-model across siblings means there's only one shape to reason about — and it leaves room to layer a non-`Send` macmon adapter later (e.g. for memory bus power) without restructuring.

The sampler thread owns `MacRamSource` outright and pushes snapshots to the HTTP layer through a `tokio::sync::watch` channel.

### Single data source

`MacRamSource` (`source.rs`) wraps `sysinfo` only. macOS doesn't separate Buffers/Cached the way `/proc/meminfo` does — Darwin's unified buffer cache rolls them into the same bucket already accounted for in `available_memory`. Those two fields are kept in the wire schema (for parity with the Linux sibling) but always serialise as `0` on macOS. The `used_bytes` math follows Linux convention: `total - available`.

### HTTP/SSE surface

`crates/mac-ram-monitord/src/http/mod.rs` wires the routes; routes only ever read the latest `Snapshot` from the `watch::Receiver` clone in `AppState`. SSE (`http/sse.rs`) wraps that receiver in `tokio_stream::wrappers::WatchStream` so each new snapshot becomes one SSE event automatically — there is no per-client buffering or sample loop on the HTTP side.

Endpoints: `/healthz`, `/v1/info`, `/v1/snapshot`, `/v1/memory`, `/v1/swap`, `/v1/processes`, `/v1/stream`. Defaults to `127.0.0.1:9135`. The port assignment is deliberate: Linux variants use the 9123-9126 band (cpu=9124, gpu=9123, ram=9125, disk=9126); Mac variants use 9133-9136 with the same trailing digit (cpu=9134, gpu=9133, ram=9135, disk=9136). That way a single Mac can simultaneously run its own backends and SSH-tunnel the Linux siblings.

### Swift menubar app

`StatusBarController.refreshIcon` dedupes via a render key (`pct:gib_x10|connected|appearance`) so identical 1-Hz ticks don't repaint. Light/dark switching listens on `AppleInterfaceThemeChangedNotification` via `DistributedNotificationCenter` — **don't KVO `effectiveAppearance` on the status item button**, the comment in that file explains the feedback loop that caused.

`SSEClient` (`Client.swift`) parses SSE manually because `Foundation.AsyncBytes.lines` collapses the blank-line frame separators; it decodes a `Snapshot` after every `data:` line on the assumption that `mac-ram-monitord` ships one self-contained JSON snapshot per event (which it does — see `http/sse.rs`).

`IconRenderer` is adapted from the CPU sibling, not copied. The donut shows used %, and the side label is the used memory in GiB (e.g. `(12.4G)`) — that's the number Activity Monitor surfaces as "Memory Used", which is the headline figure users compare against. The base icon (`Resources/ram.png`) is loaded via `Bundle.module`; `build-app.sh` copies the SwiftPM-generated resource bundle next to the binary inside the `.app/Contents/MacOS/` so `Bundle.module` resolves at runtime.

### Autostart

`front-mac/scripts/install-daemon.sh` and `install-launchagent.sh` install two LaunchAgents under `~/Library/LaunchAgents/`. The plists hardcode the absolute path to `target/release/mac-ram-monitord` and to the bundled `.app`; if the project moves on disk, regenerate them or run the install scripts again.

## When changing the schema

1. Edit `crates/mac-ram-monitor-core/src/model.rs`.
2. Mirror in `front-mac/Sources/MacRAMMonitorTray/Models.swift` — same field order, matching `CodingKeys` for the snake_case ↔ camelCase mapping.
3. Rebuild both halves: `cargo build --workspace` and `./front-mac/scripts/build-app.sh`.
4. Smoke test: `curl -s http://127.0.0.1:9135/v1/snapshot | jq` to confirm new fields serialise; the Swift side will silently ignore unknown JSON keys, so the failure mode is "field stays `nil`/`zero`" — easy to miss without an end-to-end check.

The same schema is used by the Linux `ram-monitord` at `../ram_monitor`; keep them in sync if the change is supposed to be cross-platform (e.g. so a single Home Assistant package works against both backends).
