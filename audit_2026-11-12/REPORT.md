# 证书申请、Nginx/CDN、IP 证书续约与 WARP 审计

**审计日期：** 2026-11-12

**Git 基线：** `9e3d35b`（工作区已有历史未跟踪报告，本次未修改）

**范围：** 基线工作树的 ACME/证书申请与安装、HY2 域名/IP 证书续约、CDN + Nginx 上下行域名分流、WARP 容器启停/迁移/重置与健康判定。

## 结论

本报告记录修复前确认的 10 项问题：9 项通过隔离执行复现，1 项通过调用链与官方 ACME 实现交叉核实，其中证书续约与 WARP 生命周期问题可能令已启用的服务在证书到期或容器迁移失败后不可用。

**修复状态更新（2026-11-12）：** 以上问题已修复，161 项离线回归测试及项目 ShellCheck 检查通过。修复内容、证据和验证边界见 [FIXES.md](FIXES.md)。下文及 `reproduction_results.json`、`openssl_111_evidence.json` 保留为修复前证据；`reproduce_findings.py` 断言的是旧错误行为，不是修复后的回归测试。修复后测试位于 `tests/`，OpenSSL 复验结果为 `openssl_111_fixed.json` 和 `openssl_current_fixed.json`。

位置标签中的行号对应修复前基线 `9e3d35b`；源码链接打开仓库中的对应文件，不使用已随修复移动的旧行号作为当前代码锚点。

## 发现

### P1 — 支持的旧版 OpenSSL 会让错误域名/IP 通过证书名称校验

`certificate_matches_server_name` 认为 `openssl x509 -checkhost/-checkip` 的退出码等于匹配结果。在 Ubuntu 20.04 所用 OpenSSL 1.1.1f 中，名称不匹配只打印 `does NOT match certificate`，退出码仍是 0；函数丢弃输出并直接返回该退出码。因而一对属于其他域名的有效证书/私钥，也能通过 Nginx、直连 CDN 和 HY2 共用的名称校验。客户端或 CDN Full (strict) 回源随后会拒绝该证书；这是脚本本地校验失效，并不意味着远端客户端会接受错误证书。

位置：[core/handler.sh:1333](../core/handler.sh)、[core/handler.sh:1335](../core/handler.sh)、[core/handler.sh:1337](../core/handler.sh)。用 Ubuntu 官方包提取的 OpenSSL 1.1.1f 和真实生成的证书验证：证书只有 `right.example.com`，项目完整 `validate_cdn_direct_certificate` 对 `wrong.example.com`、`192.0.2.11` 都返回 0。当前 WSL 的 OpenSSL 3.5.6 则正确返回非 0，说明这是版本兼容缺陷。

**建议：** 在支持矩阵中分别验证 OpenSSL 的返回语义。使用能可靠返回匹配结果的 API 或兼容检查，至少不能只凭旧版本命令的退出码。证据在 `openssl_111_evidence.json`，可用 `probe_openssl_compatibility.py --prefix <已解压包目录>` 复验。

### P1 — 默认配置下，CDN + Nginx 域名设置无法生成 443 分流文件

`render_nginx_stream_config` 同时要求 `.nginx.domain` 和 `.nginx.cdn` 非空，但 CDN 是独立模式，项目默认 `.nginx.domain` 为空；CDN 服务配置最终也会主动将其清空。调用者在渲染失败时回滚并中止域名变更。因此，从默认配置安装 CDN + Nginx，或成功配置后再次变更 CDN 域名，都会在此处失败。

位置：[core/handler.sh:6193](../core/handler.sh)、[core/handler.sh:6198](../core/handler.sh)、[core/handler.sh:6839](../core/handler.sh)、[core/handler.sh:4438](../core/handler.sh)。复现脚本用当前函数确认空 `domain` 返回失败。

**建议：** 按运行模式生成映射；CDN + Nginx 只依赖 CDN 域名，不应要求 SNI 的 `nginx.domain`。

### P1 — 双 CDN 域名的下行域名未进入 443 SNI 映射

模板 `stream.conf` 的 map 只有一个 CDN 名称；渲染函数也只替换 `domain` 和 `cdn`，没有读取 `.nginx.cdnDown`。当两个 CDN 分别承载上、下行，且下行 CDN 以 `cdnDown` 作为回源 SNI（没有另行覆盖为上行域名）时，回源的下行 SNI 会匹配 `default_backend`，模板对该后端执行 `ssl_reject_handshake`，因而下行 TLS 握手失败。

位置：[core/handler.sh:6193](../core/handler.sh)、[config/nginx/conf/modules-enabled/stream.conf:4](../config/nginx/conf/modules-enabled/stream.conf)、[config/nginx/conf/modules-enabled/stream.conf:5](../config/nginx/conf/modules-enabled/stream.conf)。复现确认即使人为提供旧的非空 `domain` 让渲染通过，生成结果仍无下行域名映射。

**建议：** 让渲染器接收并验证 `cdnDown`，为其生成到 CDN Nginx Unix socket 的映射，并增加上下行双域名的配置校验。

### P1 — 复用证书只重绑部署路径，不会迁移 ACME 验证方式

`install_acme_managed_certificate` 调用 `--install-cert` 更新证书文件路径和 reload 命令，但没有改变已签发记录的验证方法，也没有添加 Nginx 停启的 pre/post hook。证书在 Nginx Webroot 与 Xray 直连之间复用时，ACME 记录会继续使用原 challenge：Webroot 证书转到停止 Nginx 的直连模式后续签无法提供 HTTP-01 文件；Standalone 证书转到由 Nginx 占用 80 端口的模式后续签无法绑定 80 端口。

位置：[core/handler.sh:3247](../core/handler.sh)、[core/handler.sh:3279](../core/handler.sh)、[core/handler.sh:3804](../core/handler.sh)、[core/handler.sh:6743](../core/handler.sh)、[core/handler.sh:3852](../core/handler.sh)、[service/ssl.sh:439](../service/ssl.sh)。官方 acme.sh 的 `--install-cert` 保存安装路径与 reload/pre/post hook，不会重选 `Le_Webroot`；复用流程没有重新签发或迁移 challenge 配置。这项结论来自调用链和官方实现核对，没有请求真实 CA。

同一问题也影响 HY2 使用 standalone 时的 Nginx 端口协调：首次签发会临时停止 Nginx，但 cron 并不执行这个包装器。正常 HY2 服务切换会停止脚本托管的 Nginx，因此这里仅限续约时另行启用 Nginx 占用 80 的部署，不将其列为独立、普遍发生的缺陷。

**建议：** 在后端切换时检查现有 ACME challenge 类型；若新消费者无法服务原 challenge，应明确重新签发或写入可用的验证 hook，并在切换完成前保留旧证书/服务。

### P2 — HY2 IP 证书复用 SAN 时，专用续约任务用 SAN IP 而不是 ACME 主记录

复用已有 ECC 证书时，配置正确保存 ACME 主域名到 `hy2CertAcmeDomain`；但专用续约 cron 仍以当前目标 IP `CERT_DOMAIN` 生成 `--renew -d`。当被复用证书以另一个 IP 为主标识、当前 IP 只是 SAN 时，cron 会按 SAN IP 查找 ACME 记录，而不是续约已保存的主记录；专用续约任务失效。acme.sh 原有每日 cron 仍可能续约主记录，因此不能仅据此断言所有短期证书必然到期。复现用主 IP `192.0.2.10` 和目标 SAN IP `192.0.2.11` 确认配置记录与 cron 参数不一致。

位置：[core/handler.sh:3705](../core/handler.sh)、[core/handler.sh:4199](../core/handler.sh)、[core/handler.sh:4306](../core/handler.sh)、[core/handler.sh:4374](../core/handler.sh)。acme.sh 的续约按签发主记录定位；其 `renew -d` 会查找该名称的记录，不会按 SAN 反查主记录。

**建议：** cron 必须使用已解析并持久化的 `CERT_ACME_DOMAIN`；若该证书记录不可解析，拒绝提交配置和 cron。

### P2 — 证书过期后，脚本的手动续约入口可能先失败于“恢复安装 hook”

`handler_renew_ssl` 在调用 ACME 续约之前，先调用 `handler_restore_certificate_renewal_hooks`。后者通过 `--install-cert` 重新部署当前证书；部署函数又要求证书对尚未过期。当前证书一旦过期，hook 恢复返回失败，ACME 续约命令就不会运行，用户通过脚本菜单无法执行恢复性续签。离线复现以真实 OpenSSL 生成的过期证书确认续约入口先返回失败，替换为有效证书后才进入 ACME 调用。

位置：[core/handler.sh:3645](../core/handler.sh)、[core/handler.sh:3279](../core/handler.sh)、[core/handler.sh:6933](../core/handler.sh)、[core/handler.sh:6941](../core/handler.sh)。

**建议：** 续约命令要先运行；允许过期证书继续使用 ACME 记录，而只在新证书部署校验通过后提交。hook 恢复不能作为续约的硬前置条件。

### P2 — 通配符证书复用后，按使用主机名查找不到 ACME 主记录

`acme_main_domain_for_name` 只把 ACME 主域名或 SAN 与传入值做字面相等比较。配置主机名由 `*.example.com` 通配符证书覆盖时，查找 `api.example.com` 不会返回通配符主记录。活跃消费者收集因此遗漏证书，带指定主记录的部署回调返回成功但不重载消费者；不带主记录的 hook 恢复则返回失败。Nginx 即使收到了写入磁盘的新证书，也仍会在内存中使用旧证书。离线复现确认通配符记录存在，但消费者列表为空且 hook 恢复返回失败。

位置：[core/handler.sh:3320](../core/handler.sh)、[core/handler.sh:3371](../core/handler.sh)、[core/handler.sh:3518](../core/handler.sh)。

**建议：** 使用证书 SAN 的主机名匹配规则（包括单标签通配符），并保留 ACME 主记录名供部署、续约和清理使用。

### P2 — WARP 启动时普通连接失败可触发注销并创建新注册身份

容器每次启动都会运行 `configure_warp`。当 `mode proxy` 或 `connect` 的常规重试耗尽，`repair_registration` 会执行 `registration delete`，然后 `registration new`。因此暂时的连接或配置错误也会改变注册身份，包含用户选择“保留身份”并重建容器的场景；该选项只保留挂载数据目录，无法阻止启动脚本主动注销其中的身份。复现中仅让 `connect` 的前三次调用失败，就捕获到删除和新建注册记录的命令，随后连接成功。

位置：[config/cloudflare-warp/startup.sh:153](../config/cloudflare-warp/startup.sh)、[config/cloudflare-warp/startup.sh:157](../config/cloudflare-warp/startup.sh)、[config/cloudflare-warp/startup.sh:193](../config/cloudflare-warp/startup.sh)。

**建议：** 网络/服务暂时失败时只重试并让容器健康检查失败，不自动删除注册；仅在显式“重新注册”操作中更换身份，并对不可恢复注册错误单独分类。

### P2 — WARP 就绪判定忽略代理监听与 Docker 健康检查

`startup.sh` 将 SOCKS 40000 探测定义为“尽力”操作，探测失败仍会写 ready。宿主侧 `wait_for_warp` / `warp_health` 只看 ready 文件和 `Connected` 文本，没有检查 Docker `Health.Status`，也没有连到发布的 `127.0.0.1:40001`。因此可在本地代理不可用或健康检查已判定 unhealthy 时仍向 Xray 报告可用并提交路由。隔离复现让 40000 探测失败、Docker `exec` 返回 Connected，当前 `wait_for_warp` 和 `warp_health` 仍成功，且没有读取容器 health 状态。

位置：[config/cloudflare-warp/startup.sh:215](../config/cloudflare-warp/startup.sh)、[config/cloudflare-warp/startup.sh:312](../config/cloudflare-warp/startup.sh)、[service/docker.sh:333](../service/docker.sh)、[service/docker.sh:356](../service/docker.sh)、[service/docker.sh:1422](../service/docker.sh)。

**建议：** ready 条件要求本地 SOCKS 端口可连接；宿主还应核验 Docker 健康状态或实际 TCP 探测 `127.0.0.1:40001`。

### P1 — WARP 自动迁移先删旧容器，替代容器创建失败时不回滚

`enable_warp` 与 `repair_warp` 在检测到旧运行参数或镜像不匹配时，先 `docker rm -f` 当前容器，再启动替代容器。如果删除成功但新容器启动失败，函数直接返回错误，旧实例已被删除且没有恢复操作；正在使用 WARP 分流的配置会失去可用代理端点。仓库已有的重置事务包含备份/回滚路径，但这两个升级迁移分支没有复用它。隔离 mock 确认 `repair_warp` 删除旧容器后替代容器创建失败，退出码为失败且调用中没有恢复旧容器。

位置：[service/docker.sh:446](../service/docker.sh)、[service/docker.sh:464](../service/docker.sh)、[service/docker.sh:1436](../service/docker.sh)、[service/docker.sh:1447](../service/docker.sh)。

**建议：** 迁移复用 `prepare_warp_reset` 的备份容器事务；先启动并验证新容器，再删除旧容器，或在所有后续失败分支恢复旧实例。

## 验证与边界

- `python3 -m unittest discover -s tests -v`：99 项现有离线回归测试全部通过。
- `python3 audit_2026-11-12/reproduce_findings.py`：7 组隔离复现全部返回 `CONFIRMED`，覆盖 8 项问题（两项 CDN 问题在同一组），涵盖 CDN 分流、过期证书续约入口、通配符映射、IP SAN 续约目标、WARP 注册身份、ready 假阳性和迁移失败回滚。`CONFIRMED` 表示缺陷被复现，不表示产品已经修好。
- 另用 Ubuntu 官方 OpenSSL 1.1.1f 的真实二进制及库验证名称校验缺陷，包只解压到临时目录，未安装或替换系统 OpenSSL；项目完整证书校验函数对错误域名/IP 均返回成功。
- 复现脚本会将 Windows 检出的模板在临时目录归一为 Linux LF，避免把 CRLF 环境差异误报成生产缺陷。
- 复现仅调用项目函数、临时文件、mock 命令和本机 OpenSSL；未连接公网 CA、未修改系统 Nginx/Docker 服务，未申请或续签真实证书。
- 未验证真实 CDN 回源与真实 Cloudflare WARP 外网连接；服务商端口策略、ACME 账户限制及 Cloudflare 侧状态不在离线复现范围内。

## 外部语义核对

ACME 核对对象为官方 acme.sh 提交 `7e87a310fda61afe92e3db6ac29f81efdf53b8c0`，下载脚本 SHA-256 为 `b4d1a37add59bd50c0d7624a553e9446073b864c1006e9ffb44fa0da7adaef15`。这里只阅读源码，没有执行下载的 ACME 脚本：

- [renew 根据记录读取 Le_Webroot 并重用验证方式](https://github.com/acmesh-official/acme.sh/blob/7e87a310fda61afe92e3db6ac29f81efdf53b8c0/acme.sh#L6882)
- [installcert 保存部署参数，但不迁移 Le_Webroot](https://github.com/acmesh-official/acme.sh/blob/7e87a310fda61afe92e3db6ac29f81efdf53b8c0/acme.sh#L7379)
- [OpenSSL 1.1.1w 在打印匹配结果后把 -noout 分支返回码设为 0](https://github.com/openssl/openssl/blob/OpenSSL_1_1_1w/apps/x509.c#L868)

旧 OpenSSL 复现包来自 `https://security.ubuntu.com/ubuntu/pool/main/o/openssl/`：

| 包 | SHA-256 |
| --- | --- |
| openssl_1.1.1f-1ubuntu2.24_amd64.deb | a595ba61adb73a39076720776767dc0edb9cb7fdbe5407c08343ef27fe493c4a |
| libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb | 7cf39d70a639017d1dd7c8d36daa2258063608688e449fddf40ffdd46f992a78 |
