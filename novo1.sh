#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (override via env)
# =========================
MODEL_ID="${MODEL_ID:-openai/gpt-oss-20b}"
BRAND="${BRAND:-novo-1}"                 # lowercase brand
WORKDIR="${WORKDIR:-$PWD/novo1_build}"
HF_CACHE="${HF_CACHE:-$WORKDIR/hf_cache}"
FP16_DIR="${FP16_DIR:-$WORKDIR/fp16}"
OUT_DIR="${OUT_DIR:-$WORKDIR/out}"       # final artifacts
PKG_DIR="${PKG_DIR:-$WORKDIR/packages}"
HTTP_PORT="${HTTP_PORT:-8081}"           # http server port for download
JOBS="${JOBS:-$(nproc)}"

echo "== Novo-1 CPU Builder =="
echo "Model:      ${MODEL_ID}"
echo "Brand:      ${BRAND}"
echo "Workdir:    ${WORKDIR}"
echo "Threads:    ${JOBS}"
echo "HTTP Port:  ${HTTP_PORT}"
echo

mkdir -p "${WORKDIR}" "${HF_CACHE}" "${FP16_DIR}" "${OUT_DIR}" "${PKG_DIR}"
cd "${WORKDIR}"

# -------------------------------
# System deps (Debian/Ubuntu)
# -------------------------------
if ! command -v zstd >/dev/null 2>&1; then
  echo "Installing system packages..."
  sudo apt-get update -y
  sudo apt-get install -y git cmake build-essential python3-venv python3-pip zstd curl
fi

# -------------------------------
# Python venv + deps
# -------------------------------
if [ ! -d ".venv_novo1" ]; then
  python3 -m venv .venv_novo1
fi
# shellcheck disable=SC1091
source .venv_novo1/bin/activate
pip install --upgrade pip
pip install --upgrade "transformers>=4.42.0" huggingface_hub safetensors

# -------------------------------
# Download fp16 weights once
# -------------------------------
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

# -------------------------------
# llama.cpp: convert + quantize (CPU)
# -------------------------------
if [ ! -d "llama.cpp" ]; then
  git clone https://github.com/ggerganov/llama.cpp
fi
cd llama.cpp
pip install -r requirements.txt  # for convert-hf-to-gguf.py

# Convert HF -> GGUF f16 (CPU + RAM)
python convert-hf-to-gguf.py "${FP16_DIR}" \
  --outfile "${WORKDIR}/${BRAND}-f16.gguf" --outtype f16

# Build llama.cpp binaries
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j "${JOBS}"

# Quantize to Q4_K_M (best CPU tradeoff)
mkdir -p "${OUT_DIR}/${BRAND}-gguf"
./build/bin/quantize "${WORKDIR}/${BRAND}-f16.gguf" \
  "${OUT_DIR}/${BRAND}-gguf/${BRAND}-Q4_K_M.gguf" Q4_K_M

cd "${WORKDIR}"

# -------------------------------
# README + NOTICE (license)
# -------------------------------
cat > "${OUT_DIR}/${BRAND}-gguf/README.md" <<EOF
# ${BRAND} — GGUF Q4_K_M

CPU-optimized build of **${BRAND}**, derived from \`${MODEL_ID}\`.
- Format: GGUF \`Q4_K_M\` (good CPU latency/quality balance)
- Size: ~12–14 GB
- Serve with \`llama.cpp\` on a CPU-only VPS.

## Quick CPU test (on target VPS)
./llama.cpp/build/bin/llama-server -m ${BRAND}-gguf/${BRAND}-Q4_K_M.gguf -c 4096 -ngl 0 --port 8080 --host 0.0.0.0
# Then call the HTTP API at /completion or the OpenAI-style /v1/chat/completions (if built with that option).

EOF

cat > "${OUT_DIR}/${BRAND}-gguf/NOTICE" <<EOF
This product includes components of the OpenAI GPT-OSS-20B model (\`${MODEL_ID}\`),
released under the Apache License, Version 2.0.
Modifications and branding as "${BRAND}" by the user.
EOF

# -------------------------------
# Package + checksums
# -------------------------------
echo "== Packaging artifact =="
tar -I 'zstd -19' -cf "${PKG_DIR}/${BRAND}-gguf-Q4_K_M.tar.zst" -C "${OUT_DIR}" "${BRAND}-gguf"
sha256sum "${PKG_DIR}/${BRAND}-gguf-Q4_K_M.tar.zst" | tee "${PKG_DIR}/${BRAND}-gguf-Q4_K_M.tar.zst.sha256"

# -------------------------------
# Tiny HTTP server to download
# -------------------------------
echo
echo "== Ready to serve =="
echo "Serving directory: ${PKG_DIR}"
echo "URL: http://<THIS_GPU_SERVER_IP>:${HTTP_PORT}/"
echo "Files:"
ls -lh "${PKG_DIR}"
echo

# Simple directory server (Ctrl+C to stop). If you prefer nginx, you can install it, but this is fastest.
cd "${PKG_DIR}"
python3 -m http.server "${HTTP_PORT}"
