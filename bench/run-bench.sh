#!/usr/bin/env bash
# Benchmark an OpenAI-compatible vLLM server from a fixed client container.
# Usage: run-bench.sh <label> <host> <port> <scenario>
set -euo pipefail
LABEL=$1; HOST=$2; PORT=$3; SCEN=$4
OUT=/bench/results
DS="--dataset-name random"
mkdir -p "$OUT"
case "$SCEN" in
  decode1)  ARGS="--random-input-len 1024 --random-output-len 256 --max-concurrency 1 --num-prompts 16" ;;
  decode4)  ARGS="--random-input-len 1024 --random-output-len 256 --max-concurrency 4 --num-prompts 32" ;;
  prefill32k) ARGS="--random-input-len 32768 --random-output-len 128 --max-concurrency 1 --num-prompts 4" ;;
  mixed4)   ARGS="--random-input-len 4096 --random-output-len 512 --max-concurrency 4 --num-prompts 16" ;;
  # Real text: ShareGPT first turns for chat shapes, upstream's docs (bench/datasets/docs32k.jsonl)
  # for long prefill. Random tokens starve the drafter, so these are the numbers real use sees.
  chat1)    DS="--dataset-name sharegpt --dataset-path /bench/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
            ARGS="--sharegpt-output-len 256 --max-concurrency 1 --num-prompts 16" ;;
  chat4)    DS="--dataset-name sharegpt --dataset-path /bench/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
            ARGS="--sharegpt-output-len 256 --max-concurrency 4 --num-prompts 32" ;;
  chatmixed4) DS="--dataset-name sharegpt --dataset-path /bench/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
            ARGS="--sharegpt-output-len 512 --max-concurrency 4 --num-prompts 16" ;;
  docs32k)  DS="--dataset-name custom --dataset-path /bench/datasets/docs32k.jsonl"
            ARGS="--custom-output-len 128 --max-concurrency 1 --num-prompts 4" ;;
  *) echo "unknown scenario $SCEN"; exit 1 ;;
esac
exec vllm bench serve \
  --backend openai-chat \
  --endpoint /v1/chat/completions \
  --host "$HOST" --port "$PORT" \
  --model qwen3.8-27b \
  --tokenizer Qwen/Qwen3.8-27B-FP8 \
  $DS --seed ${SEED:-0} $ARGS \
  --ignore-eos \
  --percentile-metrics ttft,tpot,itl,e2el \
  --save-result --result-dir "$OUT" --result-filename "${LABEL}_${SCEN}.json"
