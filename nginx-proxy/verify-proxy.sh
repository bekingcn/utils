#!/usr/bin/env bash
# verify-proxy.sh —— nginx 正向代理自检（新 codespace 上跑，**纯只读，不改任何状态**）
#
# 用途：确认 host 模式修复在新实例上依然生效。第 4 步是唯一判据。
# 用法：bash verify-proxy.sh
#
# 可用环境变量覆盖：
#   CONTAINER=nginx-proxy-proxy-1  PORT=18088  COMPOSE_DIR=/workspaces/utils/nginx-proxy
#   TEST_URL=https://www.google.com

set -uo pipefail

CONTAINER="${CONTAINER:-nginx-proxy-proxy-1}"
PORT="${PORT:-18088}"
COMPOSE_DIR="${COMPOSE_DIR:-/workspaces/utils/nginx-proxy}"
TEST_URL="${TEST_URL:-https://www.google.com}"

pass=0
fail=0
ok()   { echo "  [PASS] $*"; pass=$((pass + 1)); }
no()   { echo "  [FAIL] $*"; fail=$((fail + 1)); }
info() { echo "         $*"; }

echo "===== verify-proxy ====="
echo "容器      : $CONTAINER"
echo "代理端口  : $PORT"
echo "compose   : $COMPOSE_DIR"
echo "测试目标  : $TEST_URL"
echo

# ---------- 1. compose 里的 network_mode ----------
echo "===== 1) compose 是否已是 host 模式 ====="
if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  if grep -qE "network_mode:[[:space:]]*[\"']?host" "$COMPOSE_DIR/docker-compose.yml"; then
    ok "compose 含 network_mode: host"
  else
    no "compose 里没有 network_mode: host —— 改动未提交，或新 VM 拉的是旧版"
    info "修法：cd /workspaces/utils && git add nginx-proxy/docker-compose.yml && git commit && git push"
  fi
  if grep -qE '^[[:space:]]*ports:' "$COMPOSE_DIR/docker-compose.yml"; then
    info "注意：compose 里仍有未被注释的 ports:（host 模式下建议注释掉）"
  fi
else
  no "找不到 $COMPOSE_DIR/docker-compose.yml"
fi
echo

# ---------- 2. 容器状态与网络模式 ----------
echo "===== 2) 容器实际网络模式 ====="
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  no "容器 $CONTAINER 不存在"
  info "先起来：cd $COMPOSE_DIR && docker compose up -d"
else
  running="$(docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null)"
  if [ "$running" = "true" ]; then
    ok "容器正在运行"
  else
    no "容器存在但未运行"
    info "docker start $CONTAINER"
  fi
  nm="$(docker inspect "$CONTAINER" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)"
  if [ "$nm" = "host" ]; then
    ok "network_mode = host"
  else
    no "network_mode = ${nm:-未知}（期望 host）—— 这就是故障态"
  fi
  # 附带信息：host 模式下 resolv.conf 不含 loopback 项
  rcf="$(docker exec "$CONTAINER" cat /etc/resolv.conf 2>/dev/null | grep -E '^nameserver' | tr '\n' ' ')"
  [ -n "$rcf" ] && info "容器 resolv.conf: $rcf"
fi
echo

# ---------- 3. nginx 配置语法 ----------
echo "===== 3) nginx -t（配置语法） ====="
tmp="$(mktemp)"
if docker exec "$CONTAINER" nginx -t >"$tmp" 2>&1; then
  ok "配置语法正确"
  grep -E 'syntax is ok|test is successful' "$tmp" | sed 's/^/         /' || true
else
  no "nginx -t 失败"
  sed 's/^/         /' "$tmp"
fi
rm -f "$tmp"
echo

# ---------- 4. 端到端：走代理自身请求一个外网地址 ----------
echo "===== 4) 端到端（关键判据） ====="
if ! docker exec "$CONTAINER" sh -c 'command -v curl >/dev/null 2>&1'; then
  no "容器内没有 curl，无法做端到端验证"
  info "退而求其次：docker exec $CONTAINER nslookup www.google.com"
else
  out="$(docker exec "$CONTAINER" curl -sS -o /dev/null -w '%{http_code}' \
          --max-time 15 -x "http://127.0.0.1:$PORT" "$TEST_URL" 2>&1)" || true
  code="$(printf '%s' "$out" | tail -n1 | tr -d '\r\n')"
  if [ "$code" = "200" ]; then
    ok "HTTP $code —— 代理可用"
  else
    no "HTTP ${code:-无响应}"
    case "$code" in
      502|504) info "网关类错误：容器起来了但出不去 → 回看第 2 步是否 host" ;;
      000|"")  info "连不上代理端口本身 → 检查 nginx 是否在 listen $PORT（ss -ltnp | grep $PORT）" ;;
      *)       info "定位建议：docker logs --tail 50 $CONTAINER" ;;
    esac
  fi
fi
echo

# ---------- 5. 附加信息：端口监听位置 ----------
echo "===== 5) 附加信息 ====="
echo "  --- nginx 自己报的 listen ---"
docker exec "$CONTAINER" sh -c "ss -ltnp 2>/dev/null | grep -E ':$PORT' || netstat -ltnp 2>/dev/null | grep -E ':$PORT'" 2>/dev/null \
  | sed 's/^/         /' || true
echo "  --- 平台端口转发（由使用者自行确认）---"
info "若要重启自恢复，确认 .devcontainer/devcontainer.json 含 \"forwardPorts\": [$PORT]"
info "菜单路径：VS Code 的 端口 / Ports 面板"
echo

# ---------- 汇总 ----------
echo "===== 汇总 ====="
echo "  PASS $pass   FAIL $fail"
if [ "$fail" -eq 0 ]; then
  echo "  => 代理可用。新 codespace 不欠任何动作。"
  exit 0
else
  echo "  => 有 $fail 项未通过。按上面 [FAIL] 后的提示逐项处理。"
  echo "     完整背景见 host-mode-migration-plan.md 与 nginx-dns-diagnosis.md"
  exit 1
fi
