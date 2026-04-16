mod power;

use axum::{extract::State, http::StatusCode, response::Json, routing::get, Router};
use chrono::Utc;
use nvml_wrapper::Nvml;
use serde::Serialize;
use std::sync::Arc;
use sysinfo::{Components, Disks, System};
use tokio::sync::RwLock;
use tracing::info;

use crate::power::RaplSampler;

#[derive(Serialize, Clone)]
struct Metrics {
    hostname: String,
    cpu: CpuMetrics,
    gpu: Option<GpuMetrics>,
    memory: MemoryMetrics,
    disk: DiskMetrics,
    temps: TempMetrics,
    power: PowerMetrics,
    timestamp: String,
}

#[derive(Serialize, Clone, Default)]
struct PowerMetrics {
    cpu_w: Option<f32>,
    gpu_w: Option<f32>,
}

#[derive(Serialize, Clone)]
struct CpuMetrics {
    usage_percent: f32,
    core_count: usize,
    per_core: Vec<f32>,
}

#[derive(Serialize, Clone)]
struct GpuMetrics {
    usage_percent: u32,
    vram_used_mb: u64,
    vram_total_mb: u64,
    temp_c: u32,
    fan_speed_percent: u32,
}

#[derive(Serialize, Clone)]
struct MemoryMetrics {
    used_mb: u64,
    total_mb: u64,
}

#[derive(Serialize, Clone)]
struct DiskMetrics {
    used_gb: u64,
    total_gb: u64,
}

#[derive(Serialize, Clone)]
struct TempMetrics {
    cpu_temp_c: Option<f32>,
}

struct AppState {
    metrics: RwLock<Metrics>,
}

fn get_hostname() -> String {
    hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

fn collect_cpu_metrics(sys: &System) -> CpuMetrics {
    let per_core: Vec<f32> = sys.cpus().iter().map(|c| c.cpu_usage()).collect();
    let usage_percent = if per_core.is_empty() {
        0.0
    } else {
        per_core.iter().sum::<f32>() / per_core.len() as f32
    };
    CpuMetrics {
        usage_percent,
        core_count: sys.cpus().len(),
        per_core,
    }
}

fn collect_memory_metrics(sys: &System) -> MemoryMetrics {
    MemoryMetrics {
        used_mb: sys.used_memory() / 1_048_576,
        total_mb: sys.total_memory() / 1_048_576,
    }
}

fn collect_disk_metrics() -> DiskMetrics {
    let disks = Disks::new_with_refreshed_list();
    let mut total: u64 = 0;
    let mut available: u64 = 0;
    for disk in disks.list() {
        total += disk.total_space();
        available += disk.available_space();
    }
    DiskMetrics {
        used_gb: (total - available) / 1_073_741_824,
        total_gb: total / 1_073_741_824,
    }
}

fn collect_temp_metrics(components: &Components) -> TempMetrics {
    let mut cpu_temp: Option<f32> = None;
    for component in components.list() {
        let label = component.label().to_lowercase();
        if label.contains("cpu")
            || label.contains("core")
            || label.contains("package")
            || label.contains("tctl")
            || label.contains("tccd")
            || label.contains("k10temp")
        {
            if let Some(temp) = component.temperature() {
                cpu_temp = Some(cpu_temp.map_or(temp, |t: f32| t.max(temp)));
            }
        }
    }
    TempMetrics {
        cpu_temp_c: cpu_temp,
    }
}

fn collect_gpu_metrics(nvml: &Nvml) -> (Option<GpuMetrics>, Option<f32>) {
    let Ok(device) = nvml.device_by_index(0) else {
        return (None, None);
    };
    let Ok(utilization) = device.utilization_rates() else {
        return (None, None);
    };
    let Ok(memory_info) = device.memory_info() else {
        return (None, None);
    };
    let Ok(temp) =
        device.temperature(nvml_wrapper::enum_wrappers::device::TemperatureSensor::Gpu)
    else {
        return (None, None);
    };
    let fan = device.fan_speed(0).unwrap_or(0);
    let power_w = power::nvml_power_watts(&device);

    let gpu = GpuMetrics {
        usage_percent: utilization.gpu,
        vram_used_mb: memory_info.used / 1_048_576,
        vram_total_mb: memory_info.total / 1_048_576,
        temp_c: temp,
        fan_speed_percent: fan,
    };
    (Some(gpu), power_w)
}

async fn metrics_handler(State(state): State<Arc<AppState>>) -> Json<Metrics> {
    let metrics = state.metrics.read().await;
    Json(metrics.clone())
}

async fn health_handler() -> (StatusCode, &'static str) {
    (StatusCode::OK, "ok")
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let hostname = get_hostname();
    info!("Starting watchman-agent on {}", hostname);

    let initial_metrics = Metrics {
        hostname: hostname.clone(),
        cpu: CpuMetrics {
            usage_percent: 0.0,
            core_count: 0,
            per_core: vec![],
        },
        gpu: None,
        memory: MemoryMetrics {
            used_mb: 0,
            total_mb: 0,
        },
        disk: DiskMetrics {
            used_gb: 0,
            total_gb: 0,
        },
        temps: TempMetrics { cpu_temp_c: None },
        power: PowerMetrics::default(),
        timestamp: Utc::now().to_rfc3339(),
    };

    let state = Arc::new(AppState {
        metrics: RwLock::new(initial_metrics),
    });

    // Background refresh task for sysinfo (CPU needs two samples ~500ms apart)
    let bg_state = state.clone();
    let bg_hostname = hostname.clone();
    tokio::spawn(async move {
        let mut sys = System::new_all();
        let mut components = Components::new_with_refreshed_list();
        let nvml = Nvml::init().ok();
        let mut rapl = RaplSampler::new();
        if !rapl.available() {
            info!("RAPL not available — cpu_w will be null");
        }
        let mut disk_tick: u32 = 0;
        let mut disk = collect_disk_metrics();

        loop {
            sys.refresh_all();
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            sys.refresh_all();
            components.refresh(true);

            // Refresh disk every 10 seconds (20 ticks at 500ms)
            disk_tick += 1;
            if disk_tick >= 20 {
                disk_tick = 0;
                disk = collect_disk_metrics();
            }

            let cpu_w = rapl.sample();

            let (gpu, gpu_w) = if let Some(ref nvml) = nvml {
                // NVML Device is not Send, so use spawn_blocking
                let nvml_ptr = nvml as *const Nvml as usize;
                tokio::task::spawn_blocking(move || {
                    let nvml = unsafe { &*(nvml_ptr as *const Nvml) };
                    collect_gpu_metrics(nvml)
                })
                .await
                .unwrap_or((None, None))
            } else {
                (None, None)
            };

            let metrics = Metrics {
                hostname: bg_hostname.clone(),
                cpu: collect_cpu_metrics(&sys),
                gpu,
                memory: collect_memory_metrics(&sys),
                disk: disk.clone(),
                temps: collect_temp_metrics(&components),
                power: PowerMetrics { cpu_w, gpu_w },
                timestamp: Utc::now().to_rfc3339(),
            };

            let mut lock = bg_state.metrics.write().await;
            *lock = metrics;
        }
    });

    let app = Router::new()
        .route("/metrics", get(metrics_handler))
        .route("/health", get(health_handler))
        .with_state(state);

    let addr = "0.0.0.0:8085";
    info!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
