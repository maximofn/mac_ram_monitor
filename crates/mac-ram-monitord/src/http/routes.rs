use axum::extract::State;
use axum::Json;
use mac_ram_monitor_core::{Memory, Process, Snapshot, Swap};
use serde::Serialize;

use super::AppState;

#[derive(Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub uptime_s: u64,
}

pub async fn healthz(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        uptime_s: state.started_at.elapsed().as_secs(),
    })
}

#[derive(Serialize)]
pub struct InfoResponse {
    pub backend_version: &'static str,
    pub api_version: &'static str,
    pub host: String,
    pub kernel: Option<String>,
    pub memory_total_bytes: u64,
}

pub async fn info(State(state): State<AppState>) -> Json<InfoResponse> {
    let snap = state.snapshot_rx.borrow();
    Json(InfoResponse {
        backend_version: env!("CARGO_PKG_VERSION"),
        api_version: mac_ram_monitor_core::API_VERSION,
        host: snap.host.clone(),
        kernel: snap.kernel.clone(),
        memory_total_bytes: snap.memory.total_bytes,
    })
}

pub async fn snapshot(State(state): State<AppState>) -> Json<Snapshot> {
    Json(state.snapshot_rx.borrow().clone())
}

pub async fn memory(State(state): State<AppState>) -> Json<Memory> {
    Json(state.snapshot_rx.borrow().memory)
}

pub async fn swap(State(state): State<AppState>) -> Json<Swap> {
    Json(state.snapshot_rx.borrow().swap)
}

pub async fn processes(State(state): State<AppState>) -> Json<Vec<Process>> {
    Json(state.snapshot_rx.borrow().processes.clone())
}
