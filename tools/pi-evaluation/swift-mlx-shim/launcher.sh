#!/bin/bash
# Stands in for "python -m locals.server ..." so tools/pi-evaluation/benchmark.py runs unchanged.
if [ "$1" = "-c" ]; then echo '{"mlx-swift-lm":"3.32.3","swift-transformers":"1.3.5","engine":"MLXLanguageModel via Pi AppleFoundationModel bridge"}'; exit 0; fi
model=""; port=41790
while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift;; --port) port="$2"; shift;; esac; shift; done
: "${BANANA_MLX_PROBE:?Set BANANA_MLX_PROBE to the built LocalModelProbe executable}"
exec "$BANANA_MLX_PROBE" --model "$model" --port "$port"
