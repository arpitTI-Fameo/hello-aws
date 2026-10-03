#!/usr/bin/env bash
# Deploys one tested release. Run on the server by the GitHub runner (user "deploy"):
#   bash deployment/deploy.sh <hello-aws-SHA.tar.gz> <40-char commit SHA>
#
#   /opt/hello-aws/releases/<sha>/   one folder per release (last 5 kept)
#   /opt/hello-aws/current           symlink to the live release
# If the new release fails its health check, the previous one is put back.
set -euo pipefail

ARCHIVE="${1:?usage: deploy.sh <archive.tar.gz> <commit-sha>}"
SHA="${2:?usage: deploy.sh <archive.tar.gz> <commit-sha>}"
APP_DIR="${APP_DIR:-/opt/hello-aws}"
SERVICE="${SERVICE:-hello-aws}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:3000/health}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"

RELEASES="$APP_DIR/releases"
TARGET="$RELEASES/$SHA"
STAGING="$RELEASES/.staging-$SHA"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || fail "invalid commit SHA: $SHA"
[[ -f "$ARCHIVE" ]] || fail "archive not found: $ARCHIVE"
[[ -d "$RELEASES" ]] || fail "$RELEASES does not exist (see Part 5)"

# 1. Unpack, check, install production dependencies, move into place.
if [[ -d "$TARGET" ]]; then
  echo "Release $SHA is already on the server; reusing it."
else
  rm -rf "$STAGING"
  mkdir "$STAGING"
  tar -xzf "$ARCHIVE" -C "$STAGING" --no-same-owner
  [[ "$(cat "$STAGING/COMMIT" 2>/dev/null)" == "$SHA" ]] || { rm -rf "$STAGING"; fail "COMMIT file does not match $SHA"; }
  (cd "$STAGING" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
  mv "$STAGING" "$TARGET"
fi

PREVIOUS=""
[[ -L "$APP_DIR/current" ]] && PREVIOUS="$(readlink -f "$APP_DIR/current")"

switch_to() {
  ln -sfn "$1" "$APP_DIR/current.next"
  mv -Tf "$APP_DIR/current.next" "$APP_DIR/current"   # atomic swap of the symlink
  sudo -n /usr/bin/systemctl restart "$SERVICE"
}

healthy() {
  for _ in $(seq 1 15); do
    curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# 2. Switch, restart, check; roll back on failure.
echo "Deploying $SHA"
switch_to "$TARGET"
if healthy; then
  echo "Live: $(curl -fsS "$HEALTH_URL")"
else
  echo "Health check failed. Last log lines:" >&2
  journalctl -u "$SERVICE" -n 40 --no-pager 2>/dev/null || true
  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" && "$PREVIOUS" != "$TARGET" ]]; then
    echo "Rolling back to $(basename "$PREVIOUS")" >&2
    switch_to "$PREVIOUS"
    healthy && echo "Rollback succeeded." >&2 || echo "Rollback is unhealthy too; check the server." >&2
  fi
  exit 1
fi

# 3. Keep the newest releases; never delete the live one.
CURRENT_REAL="$(readlink -f "$APP_DIR/current")"
ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's:/*$::' | tail -n +"$((KEEP_RELEASES + 1))" |
  while read -r old; do
    [[ "$old" == "$CURRENT_REAL" ]] || rm -rf "$old"
  done
