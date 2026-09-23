# nginx 正向代理故障 — 定稿总结（一页）

**状态**：✅ 已修复并实测通过（`HTTP 200`）· 2026-09-22
**入口**：就是本文件。想深挖再看索引里的存档。

---

## 一句话因果链

> `universal:2` 镜像换代 → Docker 在新镜像里的**出网转发规则未生效** →
> bridge 模式下容器包走不到 SNAT（MASQUERADE 命中数 = 0）→ 容器整体出不了公网 →
> **所有 DNS 解析一起超时**（那 91 条 `could not be resolved` 只是同一个症状重复了 91 次）。
>
> **修法**：compose 里给代理服务加 `network_mode: host` —— **绕开出故障的那一层，不是修好它**。
> 所以它对 Docker 以后怎么变都免疫；"降版本"是在跑步机上。
>
> **范围要说准**：坏的是 **compose 那条网桥（`br-xxxx`）**，不是"Docker 出网整个坏了" ——
> 同一天同一台机器上，`docker build`（**不走** compose 那条网桥）是成功的（见下方撤回表）。
> 故障是**网桥级**的，不是 daemon 级。

---

## 两件独立的事（别混成一件事）

| # | 事 | 层 | 状态 |
|---|---|---|---|
| 1 | 容器在 bridge 下出不了网（**真根因**） | 网络 | ✅ host 模式绕过 |
| 2 | `gh codespace ports forward` 报 `Connection refused` | 操作 | ✅ 选错了 codespace 实例 |

## 不是根因的（已正式撤回）

| 曾经的判断 | 定稿 |
|---|---|
| `resolver 168.63.129.16` 写错了、是根因 | **撤回。一字未改**，它在旧实例上跑过数月，从头到尾都对 |
| Docker 版本是主要差别 | 是"整代镜像换代"的**一个侧面**。iptables 双后端 / Docker 29.3→29.8 / containerd 自带→系统 / Ubuntu 24.04.4→24.04.5 **四个变量同时变、无法分离** → "只降版本"不成立 |
| 容器"出不了网桥" | 网桥**内**是通的（容器到网关 `172.18.0.1` 能收到 RST），坏在**跨出去时的 SNAT** 这一跳 |
| 是 DNS 问题 | DNS 只是一个"要出网的 UDP 包"。**出网断了它当然也断** |
| `docker build` 构建期同样出不去，要无条件加 `--network=host` | **撤回**。构建容器**不在** compose 那条网桥上（走默认网桥 / 构建沙箱）→ 同一台故障机上新镜像**构建成功**。原判是把"一条网桥坏了"错推成"Docker 出网整体坏了"<br>证据：故障实例上 compose 网桥 `172.18/16` 的 MASQUERADE 命中 **0**，默认网桥 `172.17/16` 命中 **10** |

---

## 改了什么（3 个文件）

| 文件 | 改动 |
|---|---|
| `nginx-proxy/docker-compose.yml` | +`network_mode: host`；注释整段 `ports:`；`$PWD/...` → `./...` |
| `nginx-proxy/nginx.conf` | **只 2 处**：`resolver_timeout 30s→5s`、`log_format` 补回 `$status` / `$upstream_addr` / `$request_time` |
| `nginx-proxy/prepare.sh` | 幂等；`cd "$(dirname "$0")"`；v1→v2 命令；**构建网络默认不动**（失败才自动 `--network=host` 重试） |

> `resolver 168.63.129.16` 不在改动清单里 —— 它是对的。

---

## 怎么落库（4 步，按顺序）

### 1) 把 4 个文件放进 `/workspaces/utils/nginx-proxy/`

**只放这 4 个**（本目录 `nginx-proxy/` 下就有）：

| 文件 | 说明 |
|---|---|
| `docker-compose.yml` | 直接覆盖 |
| `nginx.conf` | 直接覆盖（先 diff 一眼，见下） |
| `prepare.sh` | 直接覆盖 |
| `verify-proxy.sh` | **新增**（原来在诊断工作区根目录，没进过仓库） |

**不要动这三个**：`Dockerfile`、`.gitignore`（与仓库里一致，原样保留）、`nginx-log/`（运行期日志目录，被 gitignore）。

**传法二选一**：

```powershell
# A. VS Code 里直接拖：把本地 nginx-proxy\ 下的这 4 个文件拖到
#    资源管理器的 /workspaces/utils/nginx-proxy/ 里，覆盖同名文件

# B. 命令行（本地 Windows PowerShell；名字从 codespace 里 echo $CODESPACE_NAME 取）
$cs = "<粘贴 CODESPACE_NAME>"
$src = "C:\Users\bekin\WorkBuddy\2026-09-22-17-16-41\nginx-proxy"
foreach ($f in "docker-compose.yml","nginx.conf","prepare.sh","verify-proxy.sh") {
  D:\tools\gh_2.52.0\bin\gh codespace cp -c $cs "$src\$f" "remote:/workspaces/utils/nginx-proxy/$f"
}
```

> 覆盖前建议 diff 一眼 `nginx.conf`（你在这个实例上手改过 compose，conf 未必没动过）：
> ```bash
> diff -u /workspaces/utils/nginx-proxy/nginx.conf <你传上去的新文件>
> ```

### 2) 提交 —— 决定新实例是否零操作

```bash
cd /workspaces/utils && git ls-files nginx-proxy/ \
  && git add nginx-proxy/docker-compose.yml nginx-proxy/nginx.conf \
             nginx-proxy/prepare.sh nginx-proxy/verify-proxy.sh \
  && git commit -m "nginx-proxy: use network_mode host (bridge outbound blocked)" && git push
```

**不提交 = 没做**。当前这台 VM 上改了 compose 只对当前这台有效；重建或新开 codespace 拉的是仓库里的旧版 → 回到 bridge 模式 → 故障原样复发。

### 3) **再**改 `.devcontainer/devcontainer.json`，加 `"forwardPorts": [18088]`

顺序别反：先提交 compose 再改它，否则中途 VS Code 提示 rebuild 会退回故障态。
（当前实例**不要**为它触发重建 —— 用 VS Code 的 端口/Ports 面板手工加 18088 即可。）

### 4) 新实例上跑两条

```bash
cd /workspaces/utils/nginx-proxy && bash prepare.sh   # 建镜像 + 起容器（幂等）
bash verify-proxy.sh                                  # 纯只读自检，第 4 步是唯一判据
```

**当前这个 codespace 已经是修好的状态**，步骤 1–2 纯粹是为了"下次不再重来一遍"。

**每次进新 codespace 先跑 `echo $CODESPACE_NAME`**，任何 `gh codespace` 命令都带 `-c $CODESPACE_NAME` —— 第 2 件事就是栽在这里。

---

## 文件索引

| 文件 | 用途 | 现在还要用吗 |
|---|---|---|
| `README.md` | ← 你在这 | — |
| `nginx-dns-diagnosis.md` | 完整诊断存档（§1–§26，含逐轮撤回记录；§26 是构建期那条的更正） | 需要溯源时看；**顶部有定稿结论** |
| `host-mode-migration-plan.md` | 迁移 / 运维方案（重试清单、端口转发排障 §8） | ✅ 落库时看 |
| `nginx-proxy/` | **可直接投放的 4 个文件** + 2 个原样保留文件 | ✅ 待办 1 |
| `nginx-proxy/verify-proxy.sh` | 新 codespace 自检（纯只读，5 段） | ✅ 每次 |
| `apply-host-mode.sh` | 自动改写 compose（默认 dry-run，带备份/回滚） | 可选 |
| `host-mode-preflight.sh` | host 模式一次性预检 | ⬜ 已完成，**不用再跑** |
| `codespaces-env-diff.sh` | 环境采集对照（脚本） | ⬜ 已用完 |
| `analyze_nginx.py` + `nginx_proxy.log` | 日志与统计脚本 | ⬜ 存档 |
| `setup-host-dns.sh` | ⛔ **作废** —— 为"只有 UDP 53 被拦"准备的，你的场景是整层出不去 | ❌ 别用 |
| `env-OK.txt` / `env-BAD.txt` | 两个实例的环境采集原始数据 | ⬜ 存档（病灶定位要用） |

---

## 还想再往下钉一步的话（可选，2 分钟）

丢包的**具体位置**至今未定位，只有"MASQUERADE 命中 0"这条硬证据。两条只读命令可分开两个候选：

```bash
sudo iptables-legacy -S                      # 空表 = 排除"legacy 表先丢包"
sudo iptables -L DOCKER-BRIDGE -n -v         # 无目标网桥条目 = 指向"Docker 自己的链缺规则"
```

**新的关键线索**：故障实例上默认网桥 `172.17/16` 的 MASQUERADE 命中 **10**、compose 网桥 `172.18/16` 命中 **0**。
两个网桥命运不同 → 若"legacy 全局 DROP"成立，`172.17` 也该为 0。**所以候选更偏向"该网桥缺放行规则"**，
`DOCKER-BRIDGE` 那条命令现在是第一优先：

```bash
sudo iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE   # 复核两个网桥的计数
```

不做也不影响使用 —— host 模式已经把两条候选一起绕开了。
