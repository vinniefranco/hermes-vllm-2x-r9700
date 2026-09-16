#!/usr/bin/env bash
# Container-start prelude for the ParoQuant (W5A8 / W4A8) serve. Podman-compose translation
# of the in-container half of upstream's paroquant/run_paroquant.sh (the submodule at
# build/radiance-vllm-mxfp4, mounted at /patches): apply the radiance source patches to the
# image's vLLM, compile the MXFP4 + ParoQuant HIP kernels into site-packages, drop in the
# patched libr4d, register the `paroquant` quant method in every Python process, then hand
# the vllm args (compose `command:`) to the image's normal entrypoint.
#
# Runs on EVERY container start. Compose keeps the writable layer across restarts (upstream's
# `podman run --replace` starts pristine each time), so everything here is idempotent: the
# patches skip when their sentinel is present, the kernels rebuild only when the source is
# newer than the .so, and the sitecustomize append is guarded.
set -euo pipefail

SP=/opt/vllm/lib/python3.12/site-packages
MODEL_DIR=${PARO_MODEL_DIR:?set PARO_MODEL_DIR (dir under /models)}
DRAFTER_DIR=${PARO_DRAFTER_DIR:?set PARO_DRAFTER_DIR (dir under /models)}

die() { echo "[paro] ERROR: $*" >&2; exit 1; }

# ---- preflight: the pieces ./setup-paro produces. Fail loudly here rather than NaN or 404 later.
[ -f /patches/paroquant/radiance_paroquant.hip ] \
  || die "upstream sources missing at /patches; on the host: git submodule update --init build/radiance-vllm-mxfp4"
[ -f "/models/$MODEL_DIR/config.json" ]   || die "checkpoint missing at ./models/$MODEL_DIR; run ./setup-paro"
[ -f "/models/$DRAFTER_DIR/config.json" ] || die "drafter missing at ./models/$DRAFTER_DIR; run ./setup-paro"
# The image's own libr4d predates the gated-delta-net overflow fix and NaNs this model. Upstream
# guards this with [ -f /r4d/r4d.so ] and silently falls back; here a missing build is fatal.
[ -f /r4d/r4d.so ] || die "patched libr4d missing (./radiance-cache/libr4d/<key>/r4d.so); run ./setup-paro"

PQ_BITS=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("quantization_config") or {}).get("bits", 4))' "/models/$MODEL_DIR/config.json")
echo "[paro] model=/models/$MODEL_DIR bits=$PQ_BITS drafter=/models/$DRAFTER_DIR"
echo "[paro] PQ_I8=${RADIANCE_PQ_I8:-0} PQ_PG=${RADIANCE_PQ_PG:-0} PQ_ZPE=${RADIANCE_PQ_ZPE:-0} (configs/env/paro.env; int5 wants all three on)"

# ---- radiance source patches (same list and order as upstream run_paroquant.sh)
cd /patches
for p in patch_quark_mxfp4 patch_ar_maxbytes patch_topk_triton_rows patch_dflash_calib \
         patch_dflash_mxfp4_kv patch_rmsquant_fusion patch_verify_head patch_kv_group_size \
         patch_topk_composite patch_gdn_shared_build patch_async_dynwidth patch_step_trace \
         patch_skinny_gemm patch_dflash_selector_topk patch_dynwidth patch_ar_geometry \
         patch_gdn_merge_inproj; do
  python3 "$p.py"
done
python3 patch_qwen3_thinkoff.py || echo "[radiance] WARNING: thinkoff patch did not apply"
cp mxfp4-configs/*.json "$SP"/aiter/ops/triton/configs/gemm/
cp radiance_mxfp4.py radiance_gemm.py radiance_gdn.py radiance_gdnmerge.py radiance_rmsquant.py \
   radiance_drafthead.py radiance_verifyhead.py radiance_aroverlap.py radiance_topk.py \
   radiance_arnq.py radiance_dflash_capture.py "$SP"/
cp /r4d/r4d.so "$SP"/r4d.so
echo "[radiance] using patched r4d.so from /r4d"

# ---- HIP kernels: MXFP4 (inert for int4/int5 weights, load-bearing for PARO-MXFP4) + ParoQuant.
build() { # src dst
  if [ -f "$2" ] && [ ! "$1" -nt "$2" ]; then echo "[paro] $2 up to date"; return; fi
  echo "[paro] hipcc $1 -> $2 (a couple of minutes)"
  hipcc -O3 -w -std=c++17 -fPIC -shared --offload-arch=gfx1201 $(python3 -m pybind11 --includes) "$1" -o "$2"
}
build /patches/radiance_mxfp4_fp8.hip "$SP"/radiance_mxfp4_fp8.so
build /patches/paroquant/radiance_paroquant.hip "$SP"/radiance_paroquant_kernel.so
cp /patches/paroquant/radiance_paroquant.py /patches/paroquant/radiance_paroquant_mxfp4.py "$SP"/

# ---- register the quant method in the engine and every TP worker. Appended to the STDLIB
# sitecustomize: Ubuntu ships /usr/lib/python3.12/sitecustomize.py and it shadows any
# site-packages one (upstream's finding).
if ! grep -q radiance_paroquant /usr/lib/python3.12/sitecustomize.py; then
  cat >> /usr/lib/python3.12/sitecustomize.py <<'PY'
try:
    import radiance_paroquant  # registers the paroquant quantization config
    import radiance_paroquant_mxfp4  # and the MXFP4-weights variant (paroquant_mxfp4)
    import radiance_dflash_capture  # drafter training-data capture (inert unless RADIANCE_DFLASH_CAPTURE_DIR)
except Exception as e:
    import sys
    sys.stderr.write("[radiance.paroquant] registration failed: %r\n" % (e,))
PY
fi

# Leave the bind mounts before exec: a stale .so in the cwd precedes site-packages on sys.path.
cd /
exec /opt/radiance_entrypoint.sh "/models/$MODEL_DIR" "$@"
