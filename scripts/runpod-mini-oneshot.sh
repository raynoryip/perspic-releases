#!/usr/bin/env bash
# D-335 · RunPod mini E2E one-shot bootstrap
#
# User UX: paste ONE LINE in the RunPod web terminal:
#   bash <(curl -sSL https://gist.githubusercontent.com/.../runpod-mini-oneshot.sh)
#
# What it does (no GitHub repo access needed — everything inline):
#   1. apt: git curl cmake build-essential pkg-config libssl-dev unzip
#   2. install Rust toolchain (if absent)
#   3. write Cargo.toml + main.rs (full mini runner, mirrors src-tauri/.../llm_install.rs)
#   4. build llama.cpp from source (CUDA auto-detect)
#   5. cargo build --release the mini runner
#   6. run E2E: detect_gpu → pull_model → start_llama-server → smoke /v1/chat/completions
#
# Env overrides:
#   MODEL=qwen3-0-5b-test   # smoke (default · ~400 MB)
#   MODEL=qwen3-6-27b-ud-q4-k-xl   # real production target (~17.6 GB)
#   WORK_DIR=/workspace/d335

set -euo pipefail

WORK="${WORK_DIR:-/workspace/d335}"
MODEL="${MODEL:-qwen3-0-5b-test}"

log() { printf '\n\033[1;36m[d335]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[d335 FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ─── 1 · apt deps ─────────────────────────────────────────────────────────────
log "installing apt deps (one-time)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    curl git build-essential cmake pkg-config libssl-dev \
    unzip wget ca-certificates \
    >/dev/null || die "apt install failed"

# ─── 2 · Rust toolchain ───────────────────────────────────────────────────────
if ! command -v cargo >/dev/null 2>&1; then
    log "installing Rust toolchain (one-time, ~2-3 min)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
fi
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v cargo >/dev/null || die "Rust toolchain missing after install"

# ─── 3 · scaffold work dir + write source files inline ────────────────────────
log "scaffolding $WORK"
mkdir -p "$WORK/src" "$WORK/bin" "$WORK/models"
cd "$WORK"

cat > Cargo.toml <<'EOF_TOML'
[package]
name = "llm_install_e2e"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "llm_install_e2e"
path = "src/main.rs"

[dependencies]
tokio = { version = "1", features = ["full"] }
reqwest = { version = "0.12", features = ["stream", "json"] }
futures-util = "0.3"
sha2 = "0.10"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
clap = { version = "4", features = ["derive"] }
log = "0.4"
env_logger = "0.11"

[target.'cfg(any(target_os = "linux", target_os = "windows"))'.dependencies]
nvml-wrapper = "0.10"
EOF_TOML

cat > src/main.rs <<'EOF_RUST'
//! llm_install_e2e — D-335 standalone Path B runner (inline-embedded copy).
//! See packages/frontend-desktop/src-tauri/src/commands/llm_install.rs for the
//! Tauri-bound version this mirrors.

use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;

use clap::Parser;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const LLM_SERVICE_PORT: u16 = 8080;
const HEALTH_TIMEOUT_SECS: u64 = 30;

fn model_catalogue(id: &str) -> Option<ModelSpec> {
    match id {
        "qwen3-6-27b-ud-q4-k-xl" => Some(ModelSpec {
            url: "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf".into(),
            sha256: "".into(),
            filename: "qwen-3-6-27b-ud-q4-k-xl.gguf".into(),
        }),
        "qwen3-0-5b-test" => Some(ModelSpec {
            url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf".into(),
            sha256: "".into(),
            filename: "qwen-0-5b-test.gguf".into(),
        }),
        _ => None,
    }
}

#[derive(Debug, Clone)]
struct ModelSpec { url: String, sha256: String, filename: String }

#[derive(Debug, Serialize, Deserialize, Clone)]
struct GpuInfo {
    vendor: String,
    name: String,
    vram_mb: u64,
    driver_version: String,
    gpu_count: usize,
}

#[derive(Parser, Debug)]
struct Args {
    #[arg(short, long, default_value = "qwen3-0-5b-test")]
    model: String,
    #[arg(short, long, default_value = "/workspace/d335")]
    data_dir: PathBuf,
    #[arg(long)]
    llama_server: Option<PathBuf>,
    #[arg(long)]
    skip_download: bool,
    #[arg(long)]
    skip_serve: bool,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis().init();
    let args = Args::parse();
    let spec = model_catalogue(&args.model).ok_or_else(|| format!("unknown model: {}", args.model))?;

    let bin_dir = args.data_dir.join("bin");
    let models_dir = args.data_dir.join("models");
    tokio::fs::create_dir_all(&bin_dir).await?;
    tokio::fs::create_dir_all(&models_dir).await?;
    let model_path = models_dir.join(&spec.filename);

    println!("\n══════════════════════════════════════════════════════════════");
    println!("  D-335 · LLM install E2E runner");
    println!("══════════════════════════════════════════════════════════════");
    println!("  model     : {}", args.model);
    println!("  data dir  : {}", args.data_dir.display());
    println!("  GGUF path : {}", model_path.display());
    println!("══════════════════════════════════════════════════════════════\n");

    // A3 detect_gpu
    println!("[A3] detect_gpu …");
    let gpu = detect_gpu();
    println!("    → {:?}\n", gpu);

    // A6 pull_model
    if !args.skip_download {
        println!("[A6] pull_model · {}", spec.url);
        let t0 = Instant::now();
        download_with_resume(&spec.url, &model_path).await?;
        let dt = t0.elapsed();
        let sz = tokio::fs::metadata(&model_path).await?.len();
        println!("    → {:.2} MB in {:?} ({:.2} MB/s)\n",
            sz as f64 / 1_048_576.0, dt, (sz as f64 / 1_048_576.0) / dt.as_secs_f64());
        if !spec.sha256.is_empty() {
            println!("[A6.sha] verifying SHA256 …");
            let actual = sha256_of(&model_path).await?;
            if actual != spec.sha256 {
                return Err(format!("SHA256 mismatch: {} != {}", spec.sha256, actual).into());
            }
            println!("    → OK\n");
        }
    }

    if args.skip_serve { println!("--skip-serve set, stopping."); return Ok(()); }

    // A7 start_llm_service
    let llama_bin = resolve_llama_server(&args.llama_server, &bin_dir)?;
    println!("[A7] start_llm_service · {} -m {} --port {}", llama_bin.display(), model_path.display(), LLM_SERVICE_PORT);
    let child = Command::new(&llama_bin)
        .arg("--jinja").arg("-m").arg(&model_path)
        .arg("--port").arg(LLM_SERVICE_PORT.to_string())
        .arg("--host").arg("127.0.0.1")
        .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null())
        .spawn().map_err(|e| format!("spawn llama-server: {}", e))?;
    println!("    → spawned pid {} · listening 127.0.0.1:{}\n", child.id(), LLM_SERVICE_PORT);

    println!("[A7.warmup] sleeping 8 s for model load …");
    tokio::time::sleep(std::time::Duration::from_secs(8)).await;

    // A8 check_llm_health
    println!("[A8] check_llm_health …");
    match check_llm_health(format!("http://127.0.0.1:{}", LLM_SERVICE_PORT)).await {
        Ok(reply) => {
            println!("    → 200 OK · reply: {:?}\n", reply);
            println!("══════════════════════════════════════════════════════════════");
            println!("  PASS — full chain green");
            println!("══════════════════════════════════════════════════════════════");
        }
        Err(e) => {
            eprintln!("    → FAIL: {}\n", e);
            return Err(e.into());
        }
    }
    println!("\nllama-server still running pid {}. Stop with `pkill llama-server`.", child.id());
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn detect_gpu() -> GpuInfo {
    use nvml_wrapper::Nvml;
    match Nvml::init() {
        Err(_) => empty_gpu(),
        Ok(nvml) => {
            let driver = nvml.sys_driver_version().unwrap_or_default();
            let count = nvml.device_count().unwrap_or(0) as usize;
            if count == 0 {
                return GpuInfo { vendor: "nvidia".into(), name: "no device".into(), vram_mb: 0, driver_version: driver, gpu_count: 0 };
            }
            match nvml.device_by_index(0) {
                Ok(dev) => {
                    let name = dev.name().unwrap_or_else(|_| "Unknown".into());
                    let vram_mb = dev.memory_info().map(|m| m.total / 1_048_576).unwrap_or(0);
                    GpuInfo { vendor: "nvidia".into(), name, vram_mb, driver_version: driver, gpu_count: count }
                }
                Err(_) => empty_gpu(),
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
fn detect_gpu() -> GpuInfo { empty_gpu() }

fn empty_gpu() -> GpuInfo {
    GpuInfo { vendor: "none".into(), name: "n/a".into(), vram_mb: 0, driver_version: String::new(), gpu_count: 0 }
}

async fn download_with_resume(url: &str, dest: &PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let resume_from = tokio::fs::metadata(dest).await.map(|m| m.len()).unwrap_or(0);
    if resume_from > 0 { println!("    → resuming from {} bytes", resume_from); }
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(60 * 60 * 4)).build()?;
    let mut req = client.get(url);
    if resume_from > 0 { req = req.header("Range", format!("bytes={}-", resume_from)); }
    let resp = req.send().await?;
    let status = resp.status();
    if !status.is_success() && status.as_u16() != 206 { return Err(format!("HTTP {}", status).into()); }
    let total = resp.content_length().unwrap_or(0) + resume_from;
    let mut file = tokio::fs::OpenOptions::new().create(true).append(true).open(dest).await?;
    let mut received = resume_from;
    let mut last_pct: i32 = -1;
    let t0 = Instant::now();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let bytes = chunk?;
        file.write_all(&bytes).await?;
        received += bytes.len() as u64;
        if total > 0 {
            let pct = ((received as f64 / total as f64) * 100.0) as i32;
            if pct != last_pct {
                last_pct = pct;
                let elapsed = t0.elapsed().as_secs_f64().max(0.1);
                let mb_done = (received - resume_from) as f64 / 1_048_576.0;
                let mb_per_s = mb_done / elapsed;
                let mb_total = total as f64 / 1_048_576.0;
                let eta = if mb_per_s > 0.0 { (mb_total - received as f64 / 1_048_576.0) / mb_per_s } else { 0.0 };
                print!("\r    [{:>3}%]  {:>8.1} / {:.1} MB  ·  {:.1} MB/s  ·  ETA {:.0}s   ",
                    pct, received as f64 / 1_048_576.0, mb_total, mb_per_s, eta);
                use std::io::Write;
                std::io::stdout().flush().ok();
            }
        }
    }
    file.flush().await?;
    println!();
    Ok(())
}

async fn sha256_of(path: &PathBuf) -> Result<String, Box<dyn std::error::Error>> {
    let mut f = tokio::fs::File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).await?;
        if n == 0 { break; }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

async fn check_llm_health(base_url: String) -> Result<String, String> {
    let url = format!("{}/v1/chat/completions", base_url.trim_end_matches('/'));
    let body = serde_json::json!({
        "model": "default",
        "messages": [{ "role": "user", "content": "Reply with exactly: OK" }],
        "max_tokens": 16, "temperature": 0.0
    });
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(HEALTH_TIMEOUT_SECS)).build().map_err(|e| e.to_string())?;
    let resp = client.post(&url).json(&body).send().await.map_err(|e| format!("POST: {}", e))?;
    if !resp.status().is_success() { return Err(format!("HTTP {}", resp.status())); }
    let j: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    let content = j.get("choices").and_then(|a| a.get(0))
        .and_then(|c| c.get("message")).and_then(|m| m.get("content"))
        .and_then(|s| s.as_str()).unwrap_or("").to_string();
    if content.is_empty() { return Err("empty content".into()); }
    Ok(content)
}

fn resolve_llama_server(explicit: &Option<PathBuf>, bin_dir: &PathBuf) -> Result<PathBuf, String> {
    if let Some(p) = explicit { return Ok(p.clone()); }
    let in_bin = bin_dir.join("llama-server");
    if in_bin.exists() { return Ok(in_bin); }
    Ok(PathBuf::from("llama-server"))
}
EOF_RUST

# ─── 4 · build llama.cpp from source (CUDA auto-detect) ───────────────────────
LLAMA_BIN="$WORK/bin/llama-server"
if [ ! -x "$LLAMA_BIN" ]; then
    log "building llama.cpp from source (~5-7 min)"
    rm -rf "$WORK/llama.cpp"
    git clone --depth 1 https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp"
    cd "$WORK/llama.cpp"
    if command -v nvcc >/dev/null 2>&1; then
        log "  CUDA detected ($(nvcc --version | tail -1)) — GGML_CUDA=ON"
        cmake -B build -DGGML_CUDA=ON -DBUILD_SHARED_LIBS=OFF -Wno-dev 2>&1 | tail -3
    else
        log "  no CUDA — CPU-only build"
        cmake -B build -DBUILD_SHARED_LIBS=OFF -Wno-dev 2>&1 | tail -3
    fi
    cmake --build build --config Release --target llama-server -j"$(nproc)" 2>&1 | tail -3
    cp build/bin/llama-server "$LLAMA_BIN"
    chmod +x "$LLAMA_BIN"
    cd "$WORK"
    log "llama-server installed at $LLAMA_BIN"
else
    log "llama-server already at $LLAMA_BIN, skipping build"
fi

# ─── 5 · cargo build mini runner ──────────────────────────────────────────────
log "cargo build --release (~3-5 min first time)"
cargo build --release 2>&1 | tail -10

# ─── 6 · run E2E ──────────────────────────────────────────────────────────────
log "running E2E · model=$MODEL"
./target/release/llm_install_e2e \
    --model "$MODEL" \
    --data-dir "$WORK" \
    --llama-server "$LLAMA_BIN" 2>&1 | tee "$WORK/e2e-${MODEL}.log"

log "log saved · $WORK/e2e-${MODEL}.log"
log "to run the 27B real model next: MODEL=qwen3-6-27b-ud-q4-k-xl bash <(curl -sSL <this-gist-url>)"
