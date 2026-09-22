#!/usr/bin/env bash
# ============================================================================
# prepare.sh —— 构建镜像并启动代理（幂等，可重复执行）
#
# 用法：bash prepare.sh
#
# 为什么需要它：
#   镜像 nginx:proxy_1.80.0 不在任何 registry 上，是本地 docker build 出来的 tag
#   （见 Dockerfile：ubuntu 20.04 + 自编译 nginx 1.18.0 + proxy_connect 模块）。
#   所以每台新的 codespace 都得先跑一次本脚本，否则
#   docker compose up 会去 pull 然后失败。
#
# 关于构建期的网络 —— 别照抄"bridge 出不去所以构建也不行"这个结论：
#   构建容器 **不在 compose 那条网桥上**（compose 用 project 自建的 br-xxxx，
#   构建走默认网桥 / 构建沙箱）。实测证据：故障实例上 compose 网桥的
#   MASQUERADE 命中 = 0，而默认网桥 docker0 有非零命中（10 次新建连接）；
#   同一天在同一台机器上，不加任何网络参数就能构建成功。
#   所以「compose 出不了网」**不能推及**「构建也出不去」。
#
#   本脚本因此默认不加网络参数；仅当构建真的失败时，自动用 --network=host
#   重试一次（那种情况说明默认网桥也坏了，少见）。
# ============================================================================

set -euo pipefail

# 以脚本所在目录为基准，避免因 cwd 不同而挂错挂载路径
cd "$(dirname "$0")"

IMG="nginx:proxy_1.80.0"

if docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "[skip] 镜像 $IMG 已存在，跳过构建"
else
  echo "[build] 准备源码"
  mkdir -p nginx
  cd nginx

  [ -f nginx-1.18.0.tar.gz ] || wget http://nginx.org/download/nginx-1.18.0.tar.gz
  [ -d nginx-1.18.0 ]        || tar -zxvf nginx-1.18.0.tar.gz
  [ -d ngx_http_proxy_connect_module ] || \
    git clone https://gitee.com/web_design_of_web_frontend/ngx_http_proxy_connect_module.git

  cd ..

  echo "[build] docker build -t $IMG .   （默认网络）"
  if docker build -t "$IMG" .; then
    echo "[build] OK（默认网络）"
  else
    echo
    echo "[warn] 默认网络构建失败，改用 host 网络重试一次。"
    echo "       只有默认网桥 / 构建沙箱本身也出不去时才需要这一步（少见）。"
    docker build --network=host -t "$IMG" .
    echo "[build] OK（--network=host 兜底成功）"
  fi
fi

# host 模式下不需要发布端口，18088 直接绑在 devcontainer 上
echo "[up] docker compose up -d"
docker compose up -d

echo
echo "下一步验证（最后一条是唯一判据，期望 HTTP 200）："
echo "  docker inspect nginx-proxy-proxy-1 --format '{{.HostConfig.NetworkMode}}'"
echo "  docker exec nginx-proxy-proxy-1 nginx -t"
echo "  docker exec nginx-proxy-proxy-1 curl -sS -o /dev/null -w 'HTTP %{http_code}\\n' --max-time 15 -x http://127.0.0.1:18088 https://www.google.com"
