#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export T3_IMAGE=ghcr.io/dizys/t3code-docker@sha256:4629f4bd84ed6235e51ece1fd8cdd1eb14791e27716c2fee3b29ae89e0e93382
export T3_BUILD_TARGET=core
export PUID=1000 PGID=1000
export T3_PUBLIC_URL= T3_SINGLE_PORT= T3_SETUP_KEY= DEEPSEEK_API_KEY=

work=$(mktemp -d)
prefix="t3-smoke-$(basename "$work" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
ports=(43197 43198 43199)
started=()
environment_ids=()

compose() {
  local index=$1
  shift
  T3_PORT=${ports[$index]} docker compose --env-file /dev/null \
    --project-name "$prefix-$index" \
    -f compose.yaml -f tests/compose-multiple-instances.yaml "$@"
}

cleanup() {
  local result=$?
  trap - EXIT
  for index in "${started[@]}"; do
    if (( result != 0 )); then
      compose "$index" ps >&2 || true
    fi
    if ! compose "$index" down --volumes; then
      result=1
    fi
  done
  rmdir -- "$work"
  exit "$result"
}
trap cleanup EXIT

probe() {
  local url="http://127.0.0.1:${ports[$1]}"
  curl --fail --silent --show-error --max-time 5 "$url/" >/dev/null
  curl --fail --silent --show-error --max-time 5 "$url/api/auth/session" \
    | jq -e '.authenticated == false' >/dev/null
  curl --fail --silent --show-error --max-time 5 "$url/.well-known/t3/environment" \
    | jq -er 'select(.serverVersion == "0.1.11" and .platform.os == "linux") | .environmentId | select(type == "string" and length > 0)'
}

docker image pull --platform linux/amd64 "$T3_IMAGE"
for index in "${!ports[@]}"; do
  compose "$index" config --format json | jq -e --arg image "$T3_IMAGE" \
    --arg host_port "${ports[$index]}" '
      .services.t3code | .image == $image
      and (.ports | length == 1
        and .[0].host_ip == "127.0.0.1"
        and .[0].published == $host_port and .[0].target == 3773)
      and (.volumes | length == 3 and all(.type == "volume"))
      and (.privileged != true)
    ' >/dev/null
  started+=("$index")
  compose "$index" up -d --no-build --wait --wait-timeout 150 t3code
  container_id=$(compose "$index" ps -q t3code)
  docker inspect "$container_id" | jq -e --arg project "$prefix-$index" '
    .[0] | .State.Health.Status == "healthy"
    and (.Mounts | length == 3
      and all(.Type == "volume" and (.Name | startswith($project + "_"))))
  ' >/dev/null
done

for index in "${!ports[@]}"; do
  environment_ids[$index]=$(probe "$index")
  printf 'Port %s: T3 0.1.11, anonymous session, environment %s\n' \
    "${ports[$index]}" "${environment_ids[$index]}"
done
test "$(printf '%s\n' "${environment_ids[@]}" | sort -u | wc -l)" -eq 3

compose 0 restart t3code
for attempt in {1..30}; do
  if [[ $(probe 0 2>/dev/null) == "${environment_ids[0]}" ]]; then
    break
  fi
  sleep 1
done
for index in "${!ports[@]}"; do
  test "$(probe "$index")" = "${environment_ids[$index]}"
done
printf 'Three isolated Docker environments passed. All environment IDs survived restarting the first container.\n'
