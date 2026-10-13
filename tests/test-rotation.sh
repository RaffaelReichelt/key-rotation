#!/usr/bin/env bash
# Integration test for rotate-ts-authkey.sh against a throwaway Swarm stack.
# - curl is stubbed, so the Tailscale API is never called
# - only the secret tstest_authkey and the stack tstest are touched
# Run on a Swarm manager: ./tests/test-rotation.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/rotate-ts-authkey.sh"
STACK=tstest
SECRET=tstest_authkey
WORK="$(mktemp -d)"
FAILED=0

cleanup() {
  docker stack rm "$STACK" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    docker service ls --format '{{.Name}}' | grep -q "^${STACK}_" || break
    sleep 1
  done
  for _ in $(seq 1 30); do
    docker network ls --format '{{.Name}}' | grep -q "^${STACK}_" || break
    sleep 1
  done
  docker secret rm "$SECRET" "${SECRET}_rotating" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

check() {
  if eval "$2"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    FAILED=1
  fi
}

# Stub curl: canned responses instead of the Tailscale API
mkdir "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *oauth/token*) echo '{"access_token":"dummy-token"}' ;;
  */keys*)       echo "{\"key\":\"tskey-auth-TEST-$(date +%s%N)\"}" ;;
  *)             echo "unexpected curl call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/curl"

cat >"$WORK/rotation.env" <<EOF
TS_TAILNET=example.com
TS_OAUTH_CLIENT_ID=dummy
TS_OAUTH_CLIENT_SECRET=dummy
SECRET_NAME=$SECRET
EOF

# Old state: secret plus two services, one with a custom target and mode
printf '%s' 'tskey-auth-OLD' | docker secret create "$SECRET" - >/dev/null
cat >"$WORK/stack.yml" <<EOF
services:
  plain:
    image: alpine:3
    command: sleep infinity
    secrets: [$SECRET]
  custom:
    image: alpine:3
    command: sleep infinity
    secrets:
      - source: $SECRET
        target: custom_name
        mode: 0440
  unrelated:
    image: alpine:3
    command: sleep infinity
secrets:
  $SECRET:
    external: true
EOF
echo "Deploying test stack..."
docker stack deploy -c "$WORK/stack.yml" "$STACK" >/dev/null
for _ in $(seq 1 60); do
  [ "$(docker service ls --filter "label=com.docker.stack.namespace=$STACK" --format '{{.Replicas}}' | grep -c '^1/1$')" = 3 ] && break
  sleep 1
done

container_of() { # SERVICE
  docker ps -q --filter "label=com.docker.swarm.service.name=${STACK}_$1" | head -n1
}
secret_content() { # SERVICE FILE
  docker exec "$(container_of "$1")" cat "/run/secrets/$2"
}

old_id="$(docker secret inspect "$SECRET" --format '{{.ID}}')"
unrelated_version_before="$(docker service inspect "${STACK}_unrelated" --format '{{.Version.Index}}')"

echo "Before rotation"
check "plain sees old key"  '[ "$(secret_content plain "$SECRET")" = tskey-auth-OLD ]'
check "custom sees old key" '[ "$(secret_content custom custom_name)" = tskey-auth-OLD ]'
echo "  mode before: $(docker exec "$(container_of custom)" stat -c %a /run/secrets/custom_name)," \
  "spec: $(docker service inspect "${STACK}_custom" --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}')"

echo "Running rotation..."
PATH="$WORK/bin:$PATH" ROTATION_ENV_FILE="$WORK/rotation.env" LOCK_FILE="$WORK/lock" "$SCRIPT"

new_id="$(docker secret inspect "$SECRET" --format '{{.ID}}')"
sleep 2
new_key="$(secret_content plain "$SECRET")"

echo "After rotation"
check "secret was recreated (new ID)"       '[ "$old_id" != "$new_id" ]'
check "temporary secret is gone"            '! docker secret inspect "${SECRET}_rotating" >/dev/null 2>&1'
check "plain has a new key"                 '[[ "$new_key" == tskey-auth-TEST-* ]]'
check "custom has the same new key"         '[ "$(secret_content custom custom_name)" = "$new_key" ]'
check "custom keeps its target name"        '! docker exec "$(container_of custom)" test -e "/run/secrets/$SECRET"'
echo "  mode after: $(docker exec "$(container_of custom)" stat -c %a /run/secrets/custom_name)," \
  "spec: $(docker service inspect "${STACK}_custom" --format '{{json .Spec.TaskTemplate.ContainerSpec.Secrets}}')"
check "custom keeps mode 0440"              '[ "$(docker exec "$(container_of custom)" stat -c %a /run/secrets/custom_name)" = 440 ]'
check "unrelated service was not updated"   '[ "$(docker service inspect "${STACK}_unrelated" --format "{{.Version.Index}}")" = "$unrelated_version_before" ]'

echo "Second rotation"
PATH="$WORK/bin:$PATH" ROTATION_ENV_FILE="$WORK/rotation.env" LOCK_FILE="$WORK/lock" "$SCRIPT" >/dev/null
sleep 2
check "second run succeeds, key changed"    '[ "$(secret_content plain "$SECRET")" != "$new_key" ]'

if [ "$FAILED" = 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
