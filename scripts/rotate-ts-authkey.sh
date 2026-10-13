#!/usr/bin/env bash
# Rotates the Tailscale auth key stored as Docker Swarm secret.
# Must run on a Swarm manager node.
#
# Docker secrets are immutable and cannot be removed while a service uses them,
# so the rotation is done in two phases without ever leaving a service secretless:
#   1. create <secret>_rotating with the new key, swap it into all users of <secret>
#   2. remove <secret>, recreate it with the new key, swap back, remove <secret>_rotating
set -euo pipefail

ROTATION_ENV_FILE="${ROTATION_ENV_FILE:-/etc/tailscale-authkey-rotate/rotation.env}"
LOCK_FILE="${LOCK_FILE:-/run/lock/ts-authkey-rotate.lock}"

for bin in curl jq docker flock; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: $bin is required." >&2
    exit 1
  fi
done

if [ -f "$ROTATION_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ROTATION_ENV_FILE"
fi

: "${TS_OAUTH_CLIENT_ID:?TS_OAUTH_CLIENT_ID is required (in rotation.env)}"
: "${TS_OAUTH_CLIENT_SECRET:?TS_OAUTH_CLIENT_SECRET is required (in rotation.env)}"
: "${TS_TAILNET:?TS_TAILNET is required (for example: example.com)}"

SECRET_NAME="${SECRET_NAME:-ts_authkey}"
TMP_SECRET_NAME="${SECRET_NAME}_rotating"
TS_KEY_DESCRIPTION="${TS_KEY_DESCRIPTION:-swarm-automated-rotation}"
TS_KEY_EXPIRY_SECONDS="${TS_KEY_EXPIRY_SECONDS:-2592000}"
TS_KEY_PREAUTHORIZED="${TS_KEY_PREAUTHORIZED:-true}"
TS_KEY_EPHEMERAL="${TS_KEY_EPHEMERAL:-false}"
TS_KEY_REUSABLE="${TS_KEY_REUSABLE:-true}"
TS_KEY_TAGS="${TS_KEY_TAGS:-tag:swarm}"

if [ "$TS_KEY_EXPIRY_SECONDS" -lt 86400 ] || [ "$TS_KEY_EXPIRY_SECONDS" -gt 7776000 ]; then
  echo "ERROR: TS_KEY_EXPIRY_SECONDS must be between 86400 and 7776000." >&2
  exit 1
fi

# flock releases automatically, even after SIGKILL or power loss
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: another rotation is running ($LOCK_FILE)." >&2
  exit 1
fi

if [ "$(docker info --format '{{.Swarm.ControlAvailable}}')" != "true" ]; then
  echo "ERROR: this node is not a Swarm manager." >&2
  exit 1
fi

secret_exists() {
  docker secret inspect "$1" >/dev/null 2>&1
}

# Names of all services that mount secret $1
services_using() {
  local svc
  docker service ls --format '{{.Name}}' | while read -r svc; do
    if docker service inspect "$svc" --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}' \
      | jq -e --arg n "$1" 'any(.[]?; .SecretName == $n)' >/dev/null; then
      echo "$svc"
    fi
  done
}

# swap_secret SERVICE FROM TO: replace secret FROM by TO, keeping target path, uid, gid and mode
# (File.Mode from inspect is decimal and must be passed on as such: the CLI reads "440" as decimal, "0440" as octal)
swap_secret() {
  local svc="$1" from="$2" to="$3" target uid gid mode
  read -r target uid gid mode < <(
    docker service inspect "$svc" --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}' \
      | jq -r --arg n "$from" '.[] | select(.SecretName == $n) | "\(.File.Name) \(.File.UID) \(.File.GID) \(.File.Mode)"'
  )
  echo "  $svc: $from -> $to"
  docker service update --detach=false \
    --secret-rm "$from" \
    --secret-add "source=${to},target=${target},uid=${uid},gid=${gid},mode=${mode}" \
    "$svc" >/dev/null
}

# Leftover from an interrupted run: only clean up if nothing uses it any more
if secret_exists "$TMP_SECRET_NAME"; then
  if [ -n "$(services_using "$TMP_SECRET_NAME")" ]; then
    echo "ERROR: $TMP_SECRET_NAME is still used by a service; a previous run was interrupted. Check manually." >&2
    exit 1
  fi
  docker secret rm "$TMP_SECRET_NAME" >/dev/null
fi

echo "Requesting short-lived OAuth access token..."
oauth_response="$(
  curl -fsS --retry 3 --retry-delay 2 \
    -u "${TS_OAUTH_CLIENT_ID}:${TS_OAUTH_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" \
    -d "scope=auth_keys" \
    https://api.tailscale.com/api/v2/oauth/token
)"
oauth_token="$(jq -re '.access_token' <<<"$oauth_response")"

tags_json="$(printf '%s' "$TS_KEY_TAGS" | tr ',' '\n' | sed '/^[[:space:]]*$/d' | jq -R . | jq -s .)"

request_payload="$(
  jq -n \
    --arg description "$TS_KEY_DESCRIPTION" \
    --argjson expirySeconds "$TS_KEY_EXPIRY_SECONDS" \
    --argjson preauthorized "$TS_KEY_PREAUTHORIZED" \
    --argjson ephemeral "$TS_KEY_EPHEMERAL" \
    --argjson reusable "$TS_KEY_REUSABLE" \
    --argjson tags "$tags_json" \
    '{
      "capabilities": {
        "devices": {
          "create": {
            "reusable": $reusable,
            "ephemeral": $ephemeral,
            "preauthorized": $preauthorized,
            "tags": $tags
          }
        }
      },
      "expirySeconds": $expirySeconds,
      "description": $description
    }'
)"

echo "Creating fresh auth key via Tailscale API..."
key_response="$(
  curl -fsS \
    -X POST "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/keys" \
    -H "Authorization: Bearer ${oauth_token}" \
    -H "Content-Type: application/json" \
    --data "$request_payload"
)"
new_auth_key="$(jq -re '.key' <<<"$key_response")"

mapfile -t users < <(services_using "$SECRET_NAME")
echo "Services using $SECRET_NAME: ${users[*]:-none}"

echo "Phase 1: temporary secret $TMP_SECRET_NAME"
printf '%s' "$new_auth_key" | docker secret create "$TMP_SECRET_NAME" - >/dev/null
for svc in "${users[@]}"; do
  swap_secret "$svc" "$SECRET_NAME" "$TMP_SECRET_NAME"
done

echo "Phase 2: recreating $SECRET_NAME"
if secret_exists "$SECRET_NAME"; then
  docker secret rm "$SECRET_NAME" >/dev/null
fi
printf '%s' "$new_auth_key" | docker secret create "$SECRET_NAME" - >/dev/null
for svc in "${users[@]}"; do
  swap_secret "$svc" "$TMP_SECRET_NAME" "$SECRET_NAME"
done
docker secret rm "$TMP_SECRET_NAME" >/dev/null

echo "Auth key rotation completed successfully."
