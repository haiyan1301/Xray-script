# 证书、Nginx/CDN 与 WARP 修复记录

修复及回归测试日期：2026-11-12；最终差异复核：2026-11-13。基线：`9e3d35b`。本记录描述本次修复及验证结果；未在生产环境部署。

## 修复范围

| 审计项 | 修复后的行为 | 主要位置 |
| --- | --- | --- |
| 1. 旧版 OpenSSL 名称误判 | 同时要求命令成功及明确的名称匹配输出，拒绝“退出码为 0 但输出 NOT match” | `core/handler.sh`：`certificate_matches_server_name` |
| 2. 纯 CDN 要求 SNI 域名 | 按 SNI / CDN 模式生成配置；纯 CDN + Nginx 不再依赖空的 `nginx.domain` | `core/handler.sh`：`render_nginx_stream_config` |
| 3. 下行 CDN 缺少 443 映射 | 上下行域名均映射到 CDN TLS 后端；移除下行域名时同步移除映射，失败回滚 | `core/handler.sh`：`render_nginx_stream_config`、`handler_change_domain` |
| 4. 复用未迁移验证方式 | 在安装/复用及手动续约前，将 HTTP-01 的已保存方法切换为 Nginx webroot 或 Xray standalone；原有 cron 会读取迁移后的字段 | `core/handler.sh`：`configure_acme_certificate_challenge`、`install_acme_managed_certificate` |
| 5. IP SAN 续约任务使用错误标识 | 专用 cron 使用已解析的 `CERT_ACME_DOMAIN`，接受主 IP 或 DNS 主记录；只清理脚本拥有的任务 | `core/handler.sh`：`handler_hy2_cert`、`configure_hy2_ip_renewal_cron`；`lib/common.sh` |
| 6. 过期证书阻断手动续约 | 续约前只迁移验证配置，续约成功后才部署和校验新证书、恢复 hook；保留原有通用入口续约全部记录的语义 | `core/handler.sh`：`handler_renew_ssl`、`handler_cdn_direct_cert_role` |
| 7. 通配符消费者遗漏 | 解析单层通配符主记录/SAN，精确主记录优先；拒绝歧义或失败列表的部分输出；清理时传递实际主记录 | `core/handler.sh`：`acme_main_domain_for_name`；`service/ssl.sh`：记录操作校验与查询 |
| 8. 保留身份模式自动重注册 | mode/connect 失败只重试或退出；已有身份或注册结果不确定时保留数据；首次注册成功即记录标记 | `config/cloudflare-warp/startup.sh` |
| 9. SOCKS 不可用却报告就绪 | 就绪要求 ready、成功的 Connected 查询、40000/40001 均可连接；宿主同时检查发布端点；所有探测有时间上限 | `config/cloudflare-warp/startup.sh`、`healthcheck.sh`；`service/docker.sh` |
| 10. 迁移失败丢失旧 WARP 容器 | 自动迁移复用事务：备份原容器、镜像、注册数据和重启策略，候选健康并提交后才清理；失败可重试回滚 | `service/docker.sh`：`prepare_warp_reset`、`rollback_warp_reset`、`_warp_migrate_container` |

验证方式迁移只改动 `Le_Webroot`，保留 SAN、CA、密钥类型、短期证书 profile、续约间隔与用户 hook。DNS 验证条目保持原值，未支持的方法明确失败。读取配置时不执行其内容；拒绝路径逃逸和记录符号链接；通过同目录临时文件原子替换并保留权限。安装失败同时恢复证书对和 ACME 配置；恢复失败保留备份并输出路径。

`ssl.sh --stop-renew/--status/--info` 接受 DNS、通配符、IPv4、IPv6 主记录；`--issue` 仍只接受普通 DNS 名称。删除失败时保留本地记录和部署文件。

## 验证结果

- `python3 -B -m unittest discover -s tests -v`：**161 项全部通过**，约 55 秒。修复前基线为 99 项。
- 按仓库 CI 范围执行 ShellCheck，warning 级，沿用排除项 `SC1090,SC1091,SC2034,SC2155`：通过。
- Shell / JSON 解析检查：通过，包含在完整测试套件中；修改的 Shell 文件另做了 `bash -n` 检查。
- `git diff --check`：通过。
- 使用从 Ubuntu 官方包解压的真实 OpenSSL **1.1.1f** 复验：底层命令仍对错误名称退出 0，但项目验证器对错误域名和 IP 均返回 1。证据：`openssl_111_fixed.json`。
- 使用本机 OpenSSL **3.5.6** 对照：错误域名和 IP 均被拒绝。证据：`openssl_current_fixed.json`。

新增回归文件：

- `tests/test_cdn_stream_fixes.py`：10 项，覆盖纯 CDN、上下行映射、CRLF、无效域名与移除失败回滚。
- `tests/test_certificate_identity_fixes.py`：16 项，覆盖名称验证、通配符解析、消费者和 IP SAN 主记录续约。
- `tests/test_certificate_renewal_fixes.py`：13 项，覆盖 HTTP 验证双向迁移、DNS 保留、真实过期证书恢复、续约/安装故障和备份保留。
- `tests/test_ssl_record_validation.py`：8 项，执行完整 SSL CLI 分派，覆盖通配符/IP、非法标识、查询和删除失败。
- `tests/test_warp_lifecycle_fixes.py`：9 项，覆盖就绪判定、迁移失败、二次回滚、同镜像恢复、原目录缺失、原重启策略。

另更新现有 WARP 启动和服务测试，覆盖首次注册重试、身份保留及命令失败。

## 验证边界

测试使用隔离目录、真实 OpenSSL 证书，以及模拟的 ACME、Docker、systemctl 和 WARP CLI；没有向真实 CA 申请证书，也没有运行真实 CDN 回源、Nginx 服务或 Cloudflare WARP 隧道。Docker 守护进程在本次环境不可用，容器级部署验证未执行。

HTTP-01 仍要求域名/IP 的 80 端口挑战路径能够到达当前服务器；CDN 的跳转、拦截或访问策略需要部署环境验证。DNS 验证继续依赖已有插件及凭据。原有 ACME 部署路径或用户 hook 已损坏时，ACME 可能在签发后因旧部署动作失败而返回非零；本次过期恢复修复不承诺自动修复任意外部 hook。

普通 HY2 运行模式会停止脚本托管的 Nginx。如果用户另行启动其他服务占用 80，standalone 的自动 cron 仍需用户协调端口；本次没有增加跨进程的停启 pre/post hook。WARP 健康检查证明状态与本地代理端口可用，不证明特定外部站点的端到端连通性。
