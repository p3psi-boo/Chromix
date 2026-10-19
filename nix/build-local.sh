#!/run/current-system/sw/bin/bash
# NixOS-only local entry point; every build dependency comes from chromix.nix.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORKSPACE="$(dirname "$REPO")"
STATE="${CHROMIX_BUILD_STATE:-$HOME/.chromix-build}"
BUILD_DIR="${CHROMIX_NIX_BUILD_DIR:-/home/chromix-nix-build}"
PROFILE="${CHROMIX_BUILD_PROFILE:-portable}"
case "$PROFILE" in
  portable) performance=false ;;
  avx2) performance=true ;;
  *) echo "Unknown CHROMIX_BUILD_PROFILE: $PROFILE (portable or avx2)" >&2; exit 2 ;;
esac
OUT_LINK="${CHROMIX_OUT_LINK:-$WORKSPACE/chromix-result}"
mkdir -p "$STATE"
printf 'running\n' > "$STATE/nix-build.exit"
: > "$STATE/nix-build.output"
finish() {
  code=$?
  printf '%s\n' "$code" > "$STATE/nix-build.exit"
  printf '\n=== Chromix Nix build exited %s at %s ===\n' "$code" "$(date -u --iso-8601=seconds)"
}
trap finish EXIT
printf '\n=== Chromix Nix build started %s ===\n' "$(date -u --iso-8601=seconds)"
args=(-f "$REPO/nix/chromix.nix" --out-link "$OUT_LINK"
      --arg performanceBuild "$performance"
      --cores "${CHROMIX_JOBS:-64}" --max-jobs 8 --option build-dir "$BUILD_DIR"
      --option substituters https://cache.nixos.org)
snapshot="${CHROMIX_SOURCE_SNAPSHOT:-}"
if [ -z "$snapshot" ] && [ -e "$STATE/source-snapshot" ]; then
  snapshot="$(readlink -f "$STATE/source-snapshot")"
fi
if [ -n "$snapshot" ]; then
  args+=(--argstr sourceSnapshot "$snapshot")
  printf 'Source snapshot: %s\n' "$snapshot"
fi
checkpoint="${CHROMIX_BUILD_CHECKPOINT:-}"
# Checkpoints are explicit only. Schema 2 also binds the patch stack; never
# silently restore the previous release's objects for a new source feature.
if [ -n "$checkpoint" ]; then
  args+=(--argstr buildCheckpoint "$checkpoint")
  printf 'Native Nix checkpoint: %s\n' "$checkpoint"
fi
nix build "${args[@]}" -L --keep-failed "$@"
readlink -f "$OUT_LINK" | tee "$STATE/nix-build.output"
python3 "$REPO/nix/verify-package.py" --package "$OUT_LINK" \
  --expected-version 154.0.8037.97 | tee "$STATE/package-verification.json"
node "$REPO/nix/verify-features.mjs" "$OUT_LINK" | tee "$STATE/feature-verification.json"
