use std::net::IpAddr;

use clap::Parser;
use mac_ram_monitor_core::{DEFAULT_BIND, DEFAULT_PORT};

#[derive(Debug, Clone, Parser)]
#[command(name = "mac-ram-monitord", about = "macOS RAM monitor backend daemon", version)]
pub struct Config {
    #[arg(long, env = "MAC_RAM_MONITORD_BIND", default_value = DEFAULT_BIND)]
    pub bind: IpAddr,

    #[arg(long, env = "MAC_RAM_MONITORD_PORT", default_value_t = DEFAULT_PORT)]
    pub port: u16,

    /// Sampling cadence in milliseconds. Memory totals on macOS update every
    /// ~50 ms so this only affects how often the snapshot is republished;
    /// 1000 ms matches the Linux daemon and the CPU sibling.
    #[arg(long, env = "MAC_RAM_MONITORD_SAMPLE_INTERVAL_MS", default_value_t = 1000)]
    pub sample_interval_ms: u64,

    #[arg(long, env = "RUST_LOG", default_value = "info")]
    pub log_level: String,

    /// Number of top RAM-consuming processes to include in each snapshot. 0 disables.
    #[arg(long, env = "MAC_RAM_MONITORD_TOP_PROCESSES", default_value_t = 5)]
    pub top_processes: u32,
}
