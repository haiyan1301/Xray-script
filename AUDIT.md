# 2026-10-28 云端全面复查

本轮以 `2d2abc72e82ac8551234e8365dd1bb22d839064c` 为基线，检查引导安装、配置与分享、服务管理、防火墙归属、WARP、异地组网和维护工具。测试代码随修复一起提交，方便复跑。

| 范围 | 已修复的问题 |
| --- | --- |
| 持久配置 | 下载默认配置先暂存并验证，失败保留旧文件；成功替换前备份旧状态；拒绝非对象和多份 JSON；权限设置失败不提交 |
| 随机凭据 | 传播随机源、UUID 和 Short ID 生成错误，拒绝无效 UUID；有限输入替代无限管道，避免 `pipefail` 下 SIGPIPE 误失败 |
| 配置生成 | 单、多节点生成失败立即中止；mKCP 随机端口避开 API 端口，连续冲突有重试上限 |
| SNI 分享 | 修正 TLS/CDN 上行 + REALITY 下行的方向，补齐下行 XHTTP 模式、会话/填充元数据及 ML-DSA-65 Verify |
| 安装回滚 | 失败升级恢复旧内核及原服务运行/启用状态；回收失败安装新增的防火墙规则，回收失败时保留归属记录；防火墙查询错误不再当作规则不存在 |
| Cloudreve | 卸载失败保留数据目录；更新先拉取镜像，拉取失败保留现有服务；主容器就绪检查不再被 Redis 等辅助容器误导 |
| Nginx/证书 | 用户创建、源码安装及权限操作失败即中止；备份证书前拒绝悬空符号链接 |
| Xray 日志 | 配置校验关闭临时副本的文件日志，避免 root 校验创建私有日志后阻止 `User=xray` 启动；恢复已有托管日志的运行权限 |
| WARP | 每次启动确认注册、proxy 模式和连接命令；CLI 超时控制；监听进程或守护进程退出即失败；有界清理子进程 |
| 异地组网 | 精确匹配完整网卡名，避免误认 `xray01`；路由查询/删除失败保留重试状态；正确处理停止后 TUN 已销毁的情况 |
| 流量统计 | 不再向 API 传空参数；用 JSON 解析代替依赖排版的文本解析，API/JSON 错误返回失败 |
| GeoData 更新 | 排他锁避免 cron 与手工更新并发回滚覆盖；下载设连接与总超时 |

本轮验证环境为 Linux amd64，使用 Debian 12 与 Ubuntu 24.04 的隔离容器。回归集由原先的 31 项扩展到 88 项；Shell/JSON 语法、ShellCheck（沿用原有四类排除项）以及三份 Cloudreve Compose 配置检查通过。服务端内核矩阵由 11 组扩展为 31 组，逐组进行配置校验和实际监听检查。

升级测试使用两份独立核验的官方 `Xray-linux-64.zip`：

| 版本 | SHA-256 |
| --- | --- |
| v26.9.30 | `f851110beaff16e78d643f0ccfd9524b4a44dfd59bae3e34bb52bba378f7690e` |
| v26.10.21 | `0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978` |

复查入口：

```sh
python3 -m unittest discover -s tests -v
python3 tests/download_core.py --version v26.10.21 --output /tmp/xray-core-new
python3 tests/download_core.py --version v26.9.30 --output /tmp/xray-core-old
python3 tests/check_core_configs.py --xray /tmp/xray-core-new/xray --smoke
bash tests/run_isolated.sh debian:12-slim /tmp/xray-core-new /tmp/xray-core-old
bash tests/run_isolated.sh ubuntu:24.04 /tmp/xray-core-new /tmp/xray-core-old
```

内核检查覆盖 31 组服务端配置，并用临时 loopback TCP/UDP 端口和 Unix socket 实际启动。包括所有单节点模式、CDN 两种后端及单/双域名、全部 XHTTP 模式、VLESS Encryption、ML-DSA-65、纯 HY2/SS2022 多节点及混合多节点、反向代理。另将五类 SNI 分享链接转换为客户端配置，使用真实内核验证；流量统计使用真实本机 StatsService 验证查询和重置。

隔离生命周期测试执行固定上游安装器的真实参数解析、用户/组创建、二进制与 geodata 安装、服务单元生成、权限、配置生成、进程启停、升级及失败回滚、确认卸载。覆盖下载失败、替换二进制后失败、实际版本不符、原服务停止/禁用状态保留、旧 root 私有日志恢复，以及无效配置保持旧运行文件。发行包来自官方并校验 SHA-256。为避免依赖宿主机 systemd 和重复外网下载，只替换上游下载函数为已校验本地包，并用 `tests/fixtures/systemctl.py` 管理真实的 `xray` 用户进程。它不验证 systemd 的沙箱、cgroup、开机顺序或自动重启策略。容器不挂载宿主 Docker socket、不开放公网端口、不修改宿主机防火墙。

生命周期测试还通过本机 SOCKS 客户端 → SS2022 加密连接 → 已安装节点 → 临时 HTTP 服务传输完整响应。针对当前内核默认私网保护，仅在该容器的临时运行配置里放行 `127.0.0.1/32` 和测试 HTTP 服务的单个 TCP 端口；项目模板保持原有私网保护。

测试不等于公网链路验收：本轮未连接用户 VPS，未实际申请 ACME 证书、穿过 CDN 传输、连接 WARP 隧道或建立跨主机 TUN 网络，未实际部署 Cloudreve 数据库或源码编译 Nginx。以上分支通过隔离的失败注入测试检查状态保护；WARP 未注册状态的 `settings` / `registration show` 语义另用官方 2026.8.2115.0 客户端及真实守护进程验证。旧版自选内核与第三方客户端仍需支持所使用的协议字段。

## 之前的安装器兼容修复

该轮修复版本为 `v2026.10.28`，针对日志中的 CDN 安装失败，并检查相关安装、更新、配置生成、分享和下载流程。

| 已确认的问题 | 修复 |
| --- | --- |
| 官方安装器不再接受 `-u xray`，直接复现 `bash: unknown option -- -` | 使用当前支持的参数；固定安装器提交并校验 SHA-256，包含 GitHub 加速下载 |
| 部分更新入口提前保存版本号，失败后元数据与内核不符 | 所有入口先暂存配置，安装并核对实际版本后提交；失败时恢复内核备份 |
| 传入具体版本仍会解析为最新稳定版 | 显式版本独立处理，并校验 API 返回值和版本格式 |
| mKCP 的 `mkcp-aes128gcm` 在当前内核中无法加载 | 模板及单节点、多节点生成改用 `mkcp-legacy` / `settings.value`，分享兼容新旧 seed 字段 |
| 下载管道可能掩盖 curl 失败，ACME 可能执行未完整下载的响应 | 完整下载并检查退出状态后再解压或执行；增加超时及临时文件清理 |
| Nginx 安装命令经 `eval` 二次解析，参数边界丢失 | 使用命令参数数组，直接执行命令 |
| Xray 运行配置可能以 0644 写入或保留 0644 | 服务账户存在时采用 `root:xray` / 0640，否则采用 0600；权限失败则中止提交 |
| 服务账户、用户组创建及共享组加入失败被忽略 | 显式创建需要的组，检查每一步的退出状态 |
| Nginx 编译主动关闭栈与控制流保护 | 保留默认保护，并探测启用栈保护、栈冲突保护和控制流保护；启用 FORTIFY |
| Cloudreve Web 端口直接暴露到公网 | 新安装模板绑定 `127.0.0.1:5212`；已有容器不会被自动重建 |
| Docker 安装器清理 trap 拼接临时路径，带引号路径清理错误 | 使用子 shell 和不拼接路径的 EXIT trap |
| 文档安装命令跳过 HTTPS 证书校验 | 移除 `--no-check-certificate` 并引用脚本路径 |

验证结果：

- 31 项离线回归测试通过，含上游安装器真实参数解析、安装成功/失败/版本不符、回滚、权限和下载异常。
- 使用官方 Xray `v26.10.21`，核验下载包 SHA-256 后，通过 11 组生成配置的 `xray run -test`：Vision、XHTTP、Trojan、Fallback、HY2、SS2022、mKCP、SNI、CDN/Nginx、CDN/Xray、多节点组合。
- 项目 Shell 与 JSON 语法检查通过；ShellCheck 通过，排除现有动态 source、跨文件共享变量和声明赋值类诊断。
- 三份 Cloudreve Compose 模板通过 `docker compose config --quiet`。

复查命令：

```sh
python3 -m unittest discover -s tests -v
python3 tests/check_core_configs.py --xray /path/to/xray
```

第二条命令需要将官方压缩包中的 `geoip.dat` / `geosite.dat` 放在内核旁边。检查只生成临时配置并运行内核校验，不启动服务。

该轮未连接用户的 VPS，未进行真实 ACME 签发、系统服务安装或 CDN 公网链路测试。旧版自选内核及客户端仍需支持所使用的协议字段。
