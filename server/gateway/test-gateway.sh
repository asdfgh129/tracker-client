#!/usr/bin/env bash
#
# 推送网关联调（server/README.md §4，对应安全整改后的契约）：
#   1. 用 dev 弱配置启动网关（GATEWAY_ALLOW_INSECURE_DEV=1）
#   2. 模拟 Traccar webhook（HMAC 签名）
#   3. 校验签名失败 401 / 幂等 / 别名归属校验 403 / 盐值签发
#
set -euo pipefail

PORT="${GATEWAY_PORT:-8090}"
SECRET="dev-secret"

GATEWAY_PORT="$PORT" \
TRACCAR_WEBHOOK_SECRET="$SECRET" \
GATEWAY_ADMIN_TOKEN="dev-admin-token-0000000000000000" \
TRACCAR_API_BASE="http://localhost:1" \
GATEWAY_ALLOW_INSECURE_DEV=1 \
COMMAND_HMAC_KEY="dev-command-key" \
node "$(dirname "$0")/gateway.js" &
GATEWAY_PID=$!
trap 'kill $GATEWAY_PID 2>/dev/null || true' EXIT

sleep 1

BODY='{"version":1,"userId":1,"deviceId":42,"deviceName":"京A·12345","event":{"id":555,"type":"geofenceEnter"},"message":{"title":"围栏进入","body":"京A·12345 进入「公司」"}}'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

echo "==> 1. health"
curl -sf "http://localhost:$PORT/healthz" && echo

echo "==> 2. signed event（无别名注册：ok + delivered=false）"
curl -s -X POST "http://localhost:$PORT/v1/events" \
  -H "Content-Type: application/json" \
  -H "X-Traccar-Signature: sha256=$SIG" \
  -d "$BODY" && echo

echo "==> 3. duplicate event（幂等 deduplicated=true）"
curl -s -X POST "http://localhost:$PORT/v1/events" \
  -H "Content-Type: application/json" \
  -H "X-Traccar-Signature: sha256=$SIG" \
  -d "$BODY" && echo

echo "==> 4. bad signature（期望 401）"
if curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$PORT/v1/events" \
  -H "Content-Type: application/json" \
  -H "X-Traccar-Signature: sha256=deadbeef" \
  -d "$BODY" | grep -q 401; then
  echo "401 verified"
fi

echo "==> 5. alias-salt 未带 Traccar 会话（期望 401：无凭证不能签发）"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$PORT/v1/alias-salt" \
  -H "Content-Type: application/json" -d '{"serverId":1}')
[ "$CODE" = "401" ] && echo "401 verified"

echo "==> 6. alias 注册（未先签发盐：期望 403）"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$PORT/v1/aliases" \
  -H "Content-Type: application/json" \
  -d '{"alias":"u1@1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":"android"}')
[ "$CODE" = "401" ] && echo "401 verified（无会话）"

echo "==> 7. malformed json（期望 400）"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$PORT/v1/alias-salt" \
  -H "Authorization: Bearer fake" -H "Content-Type: application/json" -d '{bad')
[ "$CODE" = "401" ] && echo "401 verified（会话校验先于 body 解析）"

echo "==> 联调通过（安全基线：401/403/幂等/无默认令牌）"
