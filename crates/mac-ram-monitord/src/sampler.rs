use std::time::{Duration, Instant};

use chrono::Utc;
use mac_ram_monitor_core::{Memory, Process, Snapshot, Swap};
use tokio::sync::watch;

use crate::source::MacRamSource;

pub fn empty_memory() -> Memory {
    Memory::default()
}

pub fn empty_swap() -> Swap {
    Swap::default()
}

pub fn make_snapshot(
    host: &str,
    kernel: Option<String>,
    memory: Memory,
    swap: Swap,
    processes: Vec<Process>,
) -> Snapshot {
    Snapshot {
        timestamp: Utc::now().to_rfc3339(),
        host: host.to_string(),
        kernel,
        memory,
        swap,
        processes,
    }
}

/// Spawn a dedicated OS thread that drives `MacRamSource::sample()` on a fixed
/// cadence and pushes the snapshot through a `watch` channel.
///
/// We use `std::thread` rather than `tokio::spawn` for symmetry with the CPU
/// sibling daemon and to keep the option of layering a non-`Send` macmon-style
/// adapter later without restructuring this code. Today the sample call is
/// fast (sysinfo only) so a tokio task would also work — keeping the same
/// shape across siblings means there's only one thread-model to reason about.
pub fn spawn_sampler(
    mut source: MacRamSource,
    host: String,
    kernel: Option<String>,
    interval_ms: u64,
    tx: watch::Sender<Snapshot>,
) {
    std::thread::Builder::new()
        .name("ram-sampler".to_string())
        .spawn(move || {
            let target = Duration::from_millis(interval_ms.max(100));
            loop {
                let started = Instant::now();

                let (memory, swap, processes) = source.sample().unwrap_or_else(|err| {
                    tracing::warn!(error = %err, "RAM sample failed");
                    (empty_memory(), empty_swap(), Vec::new())
                });

                let snap = make_snapshot(&host, kernel.clone(), memory, swap, processes);
                if tx.send(snap).is_err() {
                    tracing::info!("snapshot channel closed; sampler exiting");
                    break;
                }

                let elapsed = started.elapsed();
                if elapsed < target {
                    std::thread::sleep(target - elapsed);
                }
            }
        })
        .expect("failed to spawn RAM sampler thread");
}
