#!/run/current-system/sw/bin/bash
# Build both outputs without replacing the currently accepted chromix-result.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORKSPACE="$(dirname "$REPO")"
STATE="${CHROMIX_VARIANTS_STATE:-$HOME/.chromix-build/updates-20261019}"
SOURCE="${CHROMIX_SOURCE_SNAPSHOT:-$(readlink -f "$HOME/.chromix-build/source-snapshot")}"
BUILD_DIR="${CHROMIX_NIX_BUILD_DIR:-/home/chromix-nix-build}"
mkdir -p "$STATE"
exec > >(tee -a "$STATE/build.log") 2>&1
printf 'running\n' > "$STATE/batch.exit"
finish() {
  code=$?
  printf '%s\n' "$code" > "$STATE/batch.exit"
  printf '\n=== Variant batch exited %s at %s ===\n' "$code" "$(date -u --iso-8601=seconds)"
}
trap finish EXIT
test -d "$SOURCE"
printf 'Source: %s\n' "$SOURCE"
if [ -L "$WORKSPACE/chromix-result" ] && [ ! -e "$WORKSPACE/chromix-before-update-result" ]; then
  nix-store --add-root "$WORKSPACE/chromix-before-update-result" --indirect \
    --realise "$(readlink -f "$WORKSPACE/chromix-result")"
fi

# Both GN configurations must pass before starting either multi-hour build.
for profile in portable avx2; do
  performance=false
  output="$WORKSPACE/chromix-next-configure-result"
  if [ "$profile" = avx2 ]; then
    performance=true
    output="$WORKSPACE/chromix-avx2-configure-result"
  fi
  printf 'configure:%s\n' "$profile" > "$STATE/phase"
  printf '\n=== Configure %s ===\n' "$profile"
  nix build -f "$REPO/nix/chromix.nix" --argstr sourceSnapshot "$SOURCE" \
    --arg configureOnly true --arg performanceBuild "$performance" \
    --out-link "$output" --cores "${CHROMIX_JOBS:-64}" --max-jobs 8 \
    --option substituters https://cache.nixos.org --option build-dir "$BUILD_DIR" \
    -L --keep-failed
done

for profile in portable avx2; do
  output="$WORKSPACE/chromix-next-result"
  if [ "$profile" = avx2 ]; then output="$WORKSPACE/chromix-avx2-result"; fi
  printf 'build-and-verify:%s\n' "$profile" > "$STATE/phase"
  mkdir -p "$STATE/$profile"
  printf '\n=== Build and verify %s ===\n' "$profile"
  CHROMIX_BUILD_STATE="$STATE/$profile" CHROMIX_SOURCE_SNAPSHOT="$SOURCE" \
    CHROMIX_BUILD_PROFILE="$profile" CHROMIX_BUILD_CHECKPOINT= \
    CHROMIX_OUT_LINK="$output" bash "$REPO/nix/build-local.sh" \
    2>&1 | tee "$STATE/$profile/nix-build.log"
done
printf 'complete\n' > "$STATE/phase"
printf 'Both variants built and verified. Existing chromix-result was not replaced.\n'
