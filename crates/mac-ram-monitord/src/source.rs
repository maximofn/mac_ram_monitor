use anyhow::Result;
use mac_ram_monitor_core::{Memory, Process, Swap};
use sysinfo::{MemoryRefreshKind, ProcessRefreshKind, ProcessesToUpdate, RefreshKind, System};

/// macOS RAM sampler. Pure `sysinfo`: memory totals, swap totals, per-process
/// RSS/VSZ. No `macmon` layer is needed — the IOReport bus only adds power
/// telemetry which the Linux schema doesn't expose, so adding it here would
/// just diverge the wire format from the sibling daemon.
///
/// On Apple Silicon `sysinfo` already reads `host_statistics64` + `vm.swapusage`,
/// so the numbers match Activity Monitor's "Memory" tab modulo definition (we
/// follow the Linux convention `used = total - available`).
pub struct MacRamSource {
    sys: System,
    top_processes: usize,
}

impl MacRamSource {
    pub fn new(top_processes: usize) -> Self {
        // Memory + processes only. Skip CPU usage refreshes — they need a
        // sleep window we don't want to pay for here.
        let refresh = RefreshKind::nothing()
            .with_memory(MemoryRefreshKind::everything())
            .with_processes(ProcessRefreshKind::nothing().with_memory());
        let mut sys = System::new_with_specifics(refresh);
        sys.refresh_memory();
        Self { sys, top_processes }
    }

    /// Pull a fresh memory + swap + process snapshot. Cheap (~few ms) — calling
    /// at 1 Hz from the dedicated sampler thread is fine.
    pub fn sample(&mut self) -> Result<(Memory, Swap, Vec<Process>)> {
        self.sys.refresh_memory();
        self.sys
            .refresh_processes(ProcessesToUpdate::All, true);

        let total = self.sys.total_memory();
        let free = self.sys.free_memory();
        // sysinfo's `available_memory` on macOS = free + speculative + inactive
        // (purgeable). That's the closest equivalent to /proc/meminfo's
        // MemAvailable; clamp `used = total - available` so it can't go negative
        // if the kernel reports `available > total` mid-refresh (rare but seen).
        let available = self.sys.available_memory().min(total);
        let used = total.saturating_sub(available);

        let memory = Memory {
            total_bytes: total,
            free_bytes: free,
            available_bytes: available,
            // Darwin doesn't separate these the way /proc/meminfo does — the
            // unified buffer cache rolls them into the same bucket that's
            // already accounted for in `available`.
            buffers_bytes: 0,
            cached_bytes: 0,
            used_bytes: used,
        };

        let swap_total = self.sys.total_swap();
        let swap_free = self.sys.free_swap();
        let swap = Swap {
            total_bytes: swap_total,
            free_bytes: swap_free,
            used_bytes: swap_total.saturating_sub(swap_free),
        };

        let processes = self.collect_top_processes(total);

        Ok((memory, swap, processes))
    }

    fn collect_top_processes(&self, total_bytes: u64) -> Vec<Process> {
        if self.top_processes == 0 || total_bytes == 0 {
            return Vec::new();
        }
        let mut all: Vec<&sysinfo::Process> = self.sys.processes().values().collect();
        // Sort by RSS desc, ties broken by PID asc for determinism — same
        // ordering as the Linux daemon so the Home Assistant "top process"
        // attribute stays stable across backends.
        all.sort_by(|a, b| {
            b.memory()
                .cmp(&a.memory())
                .then_with(|| a.pid().as_u32().cmp(&b.pid().as_u32()))
        });
        all.into_iter()
            .take(self.top_processes)
            .map(|p| {
                let rss = p.memory();
                let memory_percent = (rss as f32 / total_bytes as f32) * 100.0;
                Process {
                    pid: p.pid().as_u32(),
                    name: p.name().to_string_lossy().into_owned(),
                    rss_bytes: rss,
                    vsz_bytes: p.virtual_memory(),
                    memory_percent,
                }
            })
            .collect()
    }
}

/// Build a "kernel" string roughly equivalent to `uname -sr`.
pub fn read_kernel_version() -> Option<String> {
    let kind = sysinfo::System::kernel_version();
    let osname = sysinfo::System::name();
    match (osname, kind) {
        (Some(n), Some(v)) => Some(format!("{n} {v}")),
        (None, Some(v)) => Some(v),
        _ => None,
    }
}
