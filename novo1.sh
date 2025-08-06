#!/usr/bin/env bash
set -euo pipefail

# === Optional: enable swap if you only have 16 GB RAM ===
# sudo fallocate -l 6G /swapfile && sudo chmod 600 /swapfile
# sudo mkswap /swapfile && sudo swapon /swapfile
# echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# ---------------- Config (override via env) ----------------
MODEL_ID="${MODEL_ID:-openai/gpt-oss-20b}"
BRAND="${BRAND:-novo-1}"                 # lowercase brand
WORKDIR="${WORKDIR:-$PWD/novo1_build}"
HF_CACHE="${HF_CACHE:-$WORKDIR/hf_cache}"
FP16_DIR="${FP16_DIR:-$WORKDIR/fp16}"
OUT_DIR="${OUT_DIR:-$WORKDIR/out}"       # final artifacts
PKG_DIR="${PKG_DIR:-$WORKDIR/packages}"
HTTP_PORT="${HTTP_PORT:-8081}"           # temp download port
GGUF_QUANT="${GGUF_QUANT:-Q4_K_M}"       # best CPU tradeoff
JOBS="${JOBS:-$(nproc)}"
FAST_MODE="${FAST_MODE:-1}"              # 1 = parallel HF download & serve .gguf directly
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"           # used only when FAST_MODE=0

echo "== Novo-1 CPU Builder =="
echo "Model:      ${MODEL_ID}"
echo "Brand:      ${BRAND}"
echo "Workdir:    ${WORKDIR}"
echo "Threads:    ${JOBS}"
echo "Quant:      ${GGUF_QUANT}"
echo "FAST_MODE:  ${FAST_MODE} (1=serve .gguf directly, 0=make tarball)"
echo "HTTP Port:  ${HTTP_PORT}"
echo

mkdir -p "${WORKDIR}" "${HF_CACHE}" "${FP16_DIR}" "${OUT_DIR}" "${PKG_DIR}"
cd "${WORKDIR}"

# ---------------- System deps (Debian/Ubuntu) ---------------
echo "== Installing system packages (if needed) =="
sudo apt-get update -y
sudo apt-get install -y git cmake build-essential python3-venv python3-pip zstd curl pkg-config libcurl4-openssl-dev

# ---------------- Python venv + deps ------------------------
if [ ! -d ".venv_novo1" ]; then
  python3 -m venv .venv_novo1
fi
# shellcheck disable=SC1091
source .venv_novo1/bin/activate
pip install --upgrade pip
pip install --upgrade "transformers>=4.42.0" huggingface_hub safetensors

# FAST_MODE: parallel transfer for HF
if [ "${FAST_MODE}" = "1" ]; then
  pip install -U hf_transfer || true
  export HF_HUB_ENABLE_HF_TRANSFER=1
fi

# ---------------- Download fp16 weights ---------------------
echo "== Downloading fp16 weights =="
python - <<'PY'
import os
from huggingface_hub import snapshot_download
repo_id=os.environ.get("MODEL_ID","openai/gpt-oss-20b")
local_dir=os.environ.get("FP16_DIR","./fp16")
cache_dir=os.environ.get("HF_CACHE","./hf_cache")
snapshot_download(repo_id, local_dir=local_dir, cache_dir=cache_dir,
  allow_patterns=["*.bin","*.safetensors","*.json","*.py","*.txt","tokenizer*","*.model"])
print("Downloaded to:", local_dir)
PY

# --------------- llama.cpp: convert + quantize (CPU) --------
if [ ! -d "llama.cpp" ]; then
  git clone https://github.com/ggerganov/llama.cpp
fi
cd llama.cpp
pip install -r requirements.txt  # for convert-hf-to-gguf.py

# Build llama.cpp (try with curl; if it fails, rebuild without curl)
echo "== Building llama.cpp =="
set +e
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake_status=$?
if [ $cmake_status -ne 0 ]; then
  echo "CMake config failed; retrying with -DLLAMA_CURL=OFF"
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
fi
set -e
cmake --build build -j "${JOBS}"

# Convert HF -> GGUF fp16 (CPU + RAM)
python convert-hf-to-gguf.py "${FP16_DIR}" \
  --outfile "${WORKDIR}/${BRAND}-f16.gguf" --outtype f16

# Quantize to desired GGUF type (CPU)
mkdir -p "${OUT_DIR}/${BRAND}-gguf"
./build/bin/quantize "${WORKDIR}/${BRAND}-f16.gguf" \
  "${OUT_DIR}/${BRAND}-gguf/${BRAND}-${GGUF_QUANT}.gguf" "${GGUF_QUANT}"

cd "${WORKDIR}"

# ---------------- README + NOTICE (license) -----------------
cat > "${OUT_DIR}/${BRAND}-gguf/README.md" <<EOF
# ${BRAND} — GGUF ${GGUF_QUANT}

CPU-optimized build of **${BRAND}**, derived from \`${MODEL_ID}\`.
- Format: GGUF \`${GGUF_QUANT}\`
- Serve with \`llama.cpp\` on a CPU-only VPS.

## Quick CPU server
./llama.cpp/build/bin/llama-server -m ${BRAND}-gguf/${BRAND}-${GGUF_QUANT}.gguf -c 4096 -ngl 0 --port 8080 --host 0.0.0.0
EOF

cat > "${OUT_DIR}/${BRAND}-gguf/NOTICE" <<EOF
This product includes components of the OpenAI GPT-OSS-20B model (\`${MODEL_ID}\`),
released under the Apache License, Version 2.0.
Modifications and branding as "${BRAND}" by the user.
EOF

# ---------------- Package or direct-serve -------------------
SERVE_DIR=""
if [ "${FAST_MODE}" = "1" ]; then
  echo "== FAST_MODE: skipping tarball; will serve the .gguf directly =="
  SERVE_DIR="${OUT_DIR}/${BRAND}-gguf"
  (cd "${SERVE_DIR}" && sha256sum "${BRAND}-${GGUF_QUANT}.gguf" | tee "${BRAND}-${GGUF_QUANT}.gguf.sha256")
else
  echo "== Packaging artifact (zstd -${ZSTD_LEVEL}) =="
  tar -I "zstd -${ZSTD_LEVEL}" -cf "${PKG_DIR}/${BRAND}-gguf-${GGUF_QUANT}.tar.zst" -C "${OUT_DIR}" "${BRAND}-gguf"
  sha256sum "${PKG_DIR}/${BRAND}-gguf-${GGUF_QUANT}.tar.zst" | tee "${PKG_DIR}/${BRAND}-gguf-${GGUF_QUANT}.tar.zst.sha256"
  SERVE_DIR="${PKG_DIR}"
fi

# --------------- Tiny HTTP server to download ---------------
# Try to figure out a usable public IP for printing:
PUB_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "${PUB_IP}" ]; then
  PUB_IP="$(curl -fsS ifconfig.me || true)"
fi
[ -z "${PUB_IP}" ] && PUB_IP="<THIS_SERVER_IP>"

echo
echo "== Ready to serve =="
echo "Serving directory: ${SERVE_DIR}"
echo "URL: http://${PUB_IP}:${HTTP_PORT}/"
echo "Files:"
ls -lh "${SERVE_DIR}"
echo

# Print suggested wget commands
if [ "${FAST_MODE}" = "1" ]; then
  echo "On your prod VPS, run:"
  echo "  wget http://${PUB_IP}:${HTTP_PORT}/${BRAND}-${GGUF_QUANT}.gguf"
  echo "  wget http://${PUB_IP}:${HTTP_PORT}/${BRAND}-${GGUF_QUANT}.gguf.sha256"
  echo "  sha256sum -c ${BRAND}-${GGUF_QUANT}.gguf.sha256"
else
  echo "On your prod VPS, run:"
  echo "  wget http://${PUB_IP}:${HTTP_PORT}/${BRAND}-gguf-${GGUF_QUANT}.tar.zst"
  echo "  wget http://${PUB_IP}:${HTTP_PORT}/${BRAND}-gguf-${GGUF_QUANT}.tar.zst.sha256"
  echo "  sha256sum -c ${BRAND}-gguf-${GGUF_QUANT}.tar.zst.sha256"
  echo "  tar -I zstd -xf ${BRAND}-gguf-${GGUF_QUANT}.tar.zst"
fi
echo

# Open the port if ufw is active (best effort)
sudo ufw allow ${HTTP_PORT}/tcp >/dev/null 2>&1 || true

# Simple directory server (Ctrl+C to stop)
cd "${SERVE_DIR}"
python3 -m http.server "${HTTP_PORT}"
