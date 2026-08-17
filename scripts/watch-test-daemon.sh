#!/usr/bin/env bash
# Check the test/alpha Multica daemon feed and rebuild cube-leagent-template-test
# when the published version changes.
#
# One-shot (cron):
#   ./scripts/watch-test-daemon.sh
#
# Long-running loop (optional):
#   WATCH_TEST_LOOP=1 ./scripts/watch-test-daemon.sh
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
cd "$(dirname "$0")/.."

TAG="${TAG:-cube-leagent-template-test:local}"
STATE_FILE="${WATCH_TEST_STATE_FILE:-multica/bin-test/last-test-version}"
LOCK_FILE="${WATCH_TEST_LOCK_FILE:-multica/bin-test/watch-test-daemon.lock}"
LOG_FILE="${WATCH_TEST_LOG_FILE:-logs/watch-test-daemon.log}"
MANIFEST_BASE_URL="${MULTICA_RELEASE_MANIFEST_BASE_URL:-https://cdn.leagent.me/computer}"
INTERVAL_SEC="${WATCH_TEST_INTERVAL_SEC:-10800}"
FORCE="${WATCH_TEST_FORCE:-0}"
LOOP="${WATCH_TEST_LOOP:-0}"
BUILD_SCRIPT="${WATCH_TEST_BUILD_SCRIPT:-./scripts/build-test.sh}"

mkdir -p "$(dirname "${STATE_FILE}")" "$(dirname "${LOCK_FILE}")" "$(dirname "${LOG_FILE}")"

log() {
  local line
  line="[watch-test-daemon $(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
  printf '%s\n' "${line}" >>"${LOG_FILE}"
  if [[ -t 1 ]]; then
    printf '%s\n' "${line}"
  fi
}

fetch_test_tag() {
  local meta_file
  meta_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${meta_file}'" RETURN
  if ! curl -fsSL --http1.1 \
    --connect-timeout 30 --max-time 120 \
    --retry 3 --retry-delay 3 --retry-all-errors \
    -o "${meta_file}" \
    "${MANIFEST_BASE_URL}/metainfo.json"
  then
    echo "[watch-test-daemon] ERROR: could not fetch ${MANIFEST_BASE_URL}/metainfo.json" >&2
    return 1
  fi
  python3 - "${meta_file}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if data.get("schema_version") != 1:
    raise SystemExit(f"unsupported metainfo schema_version={data.get('schema_version')!r}")
env = (data.get("environments") or {}).get("test")
if not isinstance(env, dict):
    raise SystemExit("missing release environment 'test'")
tag = (env.get("tag") or "").strip()
if not tag:
    raise SystemExit("metainfo.json environments.test.tag is empty")
print(tag)
PY
}

image_exists() {
  docker image inspect "${TAG}" >/dev/null 2>&1
}

read_last_tag() {
  if [[ -f "${STATE_FILE}" ]]; then
    tr -d '[:space:]' <"${STATE_FILE}"
  fi
}

check_and_rebuild() {
  local latest last
  log "checking ${MANIFEST_BASE_URL}/metainfo.json environments.test"
  latest="$(fetch_test_tag)"
  last="$(read_last_tag)"
  log "latest=${latest} last_built=${last:-none} image=${TAG}"

  if [[ "${FORCE}" != "1" && -n "${last}" && "${latest}" == "${last}" ]] && image_exists; then
    log "unchanged; skipping rebuild"
    return 0
  fi

  if [[ "${FORCE}" == "1" ]]; then
    log "WATCH_TEST_FORCE=1; rebuilding ${TAG} with ${latest}"
  elif [[ -z "${last}" ]] || ! image_exists; then
    log "no previous test image/state; building ${TAG} with ${latest}"
  else
    log "version changed ${last} -> ${latest}; rebuilding ${TAG}"
  fi

  MULTICA_VERSION=test TAG="${TAG}" "${BUILD_SCRIPT}"
  printf '%s\n' "${latest}" >"${STATE_FILE}"
  log "rebuild complete: ${TAG} (${latest})"
}

run_locked() {
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "another watch-test-daemon run is in progress; skipping"
    return 0
  fi
  check_and_rebuild
}

if [[ "${LOOP}" == "1" ]]; then
  if ! [[ "${INTERVAL_SEC}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL_SEC}" -lt 60 ]]; then
    echo "[watch-test-daemon] ERROR: WATCH_TEST_INTERVAL_SEC must be an integer >= 60" >&2
    exit 1
  fi
  log "loop enabled; interval=${INTERVAL_SEC}s"
  while true; do
    run_locked || log "check failed; will retry after ${INTERVAL_SEC}s"
    sleep "${INTERVAL_SEC}"
  done
fi

run_locked
