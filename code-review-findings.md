# Xray-script 代码审查报告：逻辑错误与交互逻辑缺陷

> 审查范围：`install.sh`、`core/*.sh`（main/menu/handler/read/check/generate/share/lan）、`service/*.sh`（nginx/ssl/docker）、`tool/*.sh`、`config/xray/*.json` 模板。
> 方法：逐文件通读 + 8 个并行深审代理 + 对抗性复核（60 条原始发现 → 49 条确认，另人工核对补充 2 条）。
> 结论：**未修改任何代码**，以下按影响程度归类，均标注 `文件:行号` 与触发场景。

---

## 一、高影响缺陷（导致功能失效或安全防护丢失）

### 1. Vision 防偷模式（anti-steal）在默认"保留规则"下被静默丢弃
`core/handler.sh:2310`

- 新建 Vision 时 `exec_read 'rules'` 默认 `n` → `.xray.rules.reset=0`，走 `XRAY_RULES_STATUS==0` 分支：`.routing.rules = $rules`，用状态文件里仅含 `[api, private-ip]` 的 `.rules` **覆盖**了 Vision 模板自带的 `anti-steal-allow / anti-steal-block` 规则。
- 后续 `handler.sh:2321-2330` 只对"已存在的" `anti-steal-allow` 做 `domain` 更新（`select()` 匹配不到时是 no-op），**不会重建**规则。
- 结果：`anti-steal-in` inbound 仍在，但无任何路由规则命中它 → 非白名单 SNI 探针不再被 block，直接转发到目标 443，防偷失效。且 `.rules` 在 `handler.sh:2352` 写回后已不含 anti-steal，**之后重置也恢复不了**。

**触发场景**：Vision 全新安装 / XHTTP→Vision 切换，用户对 "是否重置路由规则 [y/N]" 直接回车。

---

### 2. SNI 模式的 CDN 域名无法通过交互式输入配置（校验逻辑自相矛盾）
`core/handler.sh:573-601`（`exec_read 'cdn'`）

- 纯 CDN 模式对 cdn 域名只做 `--domain-format`（正确，CDN 域名解析到 CDN 边缘）；但 **SNI 模式**（`config_tag != 'cdn'`）走 `exec_check '--dns'`，即 `check_dns_resolution` → `dns_resolution`，**要求域名必须解析到本机源站公网 IP**。
- SNI 的 CDN 域名（"套用 CDN 的域名"）必然经 Cloudflare/国内 CDN 解析到边缘节点，**永远不指向源站** → 校验永远失败 → `exec_read` 无限重提示，无法继续。

**影响**：同一函数的所有调用点——SNI 首次安装、以及"修改 CDN 域名"菜单（`handler_change_domain` 同样走 `exec_read 'cdn'`）。

---

### 3. 异地组网（LAN）菜单操作全部不生效：只改脚本配置，从不重新生成 Xray 运行时配置
`core/lan.sh:384 / 300 / 486 / 464`，`core/main.sh:1002-1018`

- `handler_apply_lan_config`（生成 `lan-hub-in` inbound 与路由）**只在 `handler_xray_config` 内被调用**（`handler.sh:2069, 2347`）。
- `--lan-enable / --lan-add / --lan-remove / --lan-disable` 只 `write_config` 改 `SCRIPT_CONFIG` 后 `--restart`；`handler_restart` 只做服务操作、**不重建配置**。
- 结果：
  - **启用 Hub** 后运行时配置里根本没有 `lan-hub-in`，Hub 端口不监听 → 组网实际不通；
  - **添加地点** 后 Hub 侧客户列表不更新，新地点连不上；
  - **禁用** 后旧 `lan-hub-in` 仍留在运行时配置里，Hub 继续监听。
- 只有"重新安装/重配协议"（触发 `handler_xray_config`）才会真正部署 LAN。

**触发场景**：安装任意协议 → 配置管理 → 异地组网 → 启用并初始化 Hub / 添加地点 → 服务重启后 Hub 并未部署。

---

### 4. 反向代理菜单"启用/禁用"两个选项都只是 toggle，选哪个都可能做相反的事
`core/main.sh:987-989`，`core/handler.sh:5861`

- `menu_reverse` 选项 1=启用、2=禁用，但 `processes_reverse` 把 `1|2` 都映射到 `--reverse`；`handler_reverse_toggle` 是纯状态翻转（`reverse_status==1` 则禁，否则启）。
- 已启用时选"1. 启用" → 实际**禁用**；已禁用时选"2. 禁用" → 实际**启用**。标签承诺幂等、行为却取反。

---

### 5. "CDN / SNI 站点管理"在非 CDN/SNI 配置下直接退出整个会话
`core/main.sh:906`

- 配置菜单第 3 项恒显示该入口；`processes_web_mode_config` 对 `tag` 非 sni/cdn（含 Vision、XHTTP、hy2、多节点甚至空 tag）走 `_error`，而 `_error` 是 `exit 1`，**把用户踢回 shell**，而不是返回菜单提示。
- 同类问题：`handler_change_xray_port`（`handler.sh:3886`）对 CDN/SNI/multi 用 `_error` 直接退出整个会话（"修改 Xray 端口"入口对这几类模式不可用时同样粗暴退出）。

---

### 6. 路由菜单添加的规则只写运行时、不持久化，下次重配被静默丢弃
`core/handler.sh:1276` → `add_rule`（`1246` 只写 `XRAY_CONFIG_PATH`）

- `handler_routing` 通过 `add_rule` 追加 block/warp 规则后，**从不回写 `SCRIPT_CONFIG['.rules']`**。
- 下次 `--xray-config` 且用户回答"保留规则"(reset=0) 时，`handler.sh:2310` 用旧的 `.rules` 覆盖，刚加的规则消失。

**触发场景**：路由菜单加规则 → 之后任意一次协议重配 → WARP 分流/屏蔽规则静默失效。

---

### 7. 每次协议重配会静默清空 `.xray.lan`（reset 保留清单遗漏）
`core/handler.sh:1296`

- `handler_reset_script_config` 的 keep-list（version/githubProxy/warp/rules/cdnBackend/证书字段/hy2CertAcmeDomain）**不含 `.xray.lan`**。
- 重配任何协议都会把 LAN 配置（enabled/port/sites 等）清空并禁用，用户需重做整个 LAN 问卷。keep-list 明显是人工精心挑选的（注释说明了证书字段的保留理由），漏掉 `lan` 更像疏忽。

---

## 二、交互逻辑不合理

### 8. 菜单流程为单次执行、无循环；失败/完成后直接退回 shell
`core/main.sh` `processes_index` 等所有流程无 while 循环

- 执行完一个动作即退出。配合第 5、9、12 条的 `_error/exit`，用户在一个操作失败后就丢失整个菜单会话，需重跑 `bash install.sh`。

---

### 9. "0. 取消" CDN 回源后端 / 伪装站点子菜单会回滚整个协议安装
`core/main.sh:721`、`core/main.sh:103`

- `choose_cdn_backend`/`choose_web_backend` 对任何非 1/2/3 输入（含 0=取消）返回 1，`install_protocol` 立即 `return 1` 触发完整回滚（配置+运行时+nginx journal），用户以为只是取消子菜单，实际整次安装被撤销并退出。

---

### 10. `--purge` 只卸载 Xray，遗留 nginx / acme.sh / 证书 / Docker 容器 / cron / 防火墙规则
`core/handler.sh:4005`

- 仅执行 Xray-install 的 `remove --purge` + 重置 `.xray`；不删 acme.sh、nginx 及其证书、WARP/Cloudreve 容器、`handler_nginx_cron`/`handler_geodata_cron`/hy2 续签 cron。
- 全脚本**没有任何"关防火墙端口"的函数**（`open_xray_firewall_port` 只加不开），`--purge` 后 ufw/firewalld 里的旧端口仍开放。菜单选项只写"卸载"，用户易误解为完全卸载。

---

### 11. 反向代理"禁用"不关闭防火墙端口、不清理配置与规则
`core/handler.sh:5931`

- disable 只设 `.xray.reverse=0` 并重配，但：不删除 `reverseUuid/Port/Target/Mode` 字段；不开 `ufw delete`/`firewall-cmd --remove-port`（脚本无此能力）；`.rules` 里遗留的 `reverse-portal` 规则在下次任意重配时被恢复成一个悬空规则（指向已删除的 inbound）。

---

### 12. 大量 `exec_handler` 返回值被丢弃，失败被当作成功
`core/main.sh:875 / 832 / 912-918 / 1034-1035`

- `processes_routing` 的 `--restart`、`processes_xray` 的 `--install`、web-mode 菜单的 `--change-domain/--renew-certificate/--nginx-update`、管理菜单的 `--change-port/--geodata-cron` 均不检查退出码。
- 例如 `handler_restart` 失败（Xray 起不来）仍显示成功；`handler_nginx_update`（`handler.sh:4415`）同样忽略 nginx.sh 的退出状态。

---

### 13. 多节点模式端口"默认 443"仅对第一个节点成立
`core/handler.sh:717`

- `generate_unique_multi_port` 只在 `used_ports` 为空（首节点）且非 mKCP 时用 443；第 2..N 个节点按回车会**静默生成随机端口**，与 `read.sh` 提示"默认: 443"相矛盾，用户从分享链接才察觉。

---

### 14. `handler_web` 忽略 Cloudreve 容器启停失败
`core/handler.sh:5757-5764`

- `handler_cloudreve_v4 'stop'`/`'start'` 等不加 `|| return 1`，sed 改站点配置也不检查；容器没起来也照常重启 nginx、写 `.nginx.web`、返回成功。

---

### 15. `handler_warp` 的 `write_config` 不检查返回值
`core/handler.sh:4318`

- 状态文件写入失败（磁盘满/权限）会被忽略，运行时配置已含/已删 WARP 出站而 `.xray.warp` 仍是旧值，下次重配从旧状态重建导致 WARP 被意外还原。

---

### 16. install.sh 语言选择写入不检查失败
`install.sh:887-889, 891-893`

- `jq`/`backup_config`/`write_config` 均不检查；写失败时仍继续启动 main.sh，用户选的语言被静默丢弃、无提示。与第 858 行 `.path` 写回（有检查）不一致。

---

### 17. `install.sh --lang=`（空值）会清空已保存语言
`install.sh:890`

- `parse_args` 原样存 `--lang=`，`[[ "${LANG_PARAM}" =~ ^--lang= ]]` 命中 → 写入 `.language=""`，把用户之前选的英文覆盖成默认中文。

---

## 三、逻辑错误 / 边界情况

### 18. hy2 IP 续签 cron 的"旧格式清理"会误删普通域名的续签行
`core/handler.sh:3164-3165`

- 清理条件 `== "${legacy_prefix}"*"${legacy_suffix}"` 只匹配前后缀，**不校验标识符是不是 IP**；而 `main.sh:397-412` 的 `is_managed_hy2_ip_cron_line` 会校验 IP。两处不一致。
- 用户手动保留的 `--renew -d example.com ...` 这类普通域名续签行，会在任意非 hy2 协议 `handler_restart` 时被删除，且回滚逻辑（`restore_managed_hy2_ip_cron` 只恢复"受管"行）不会补回。

---

### 19. "仅更新域名"用裸 `sed s|old|new|g` 做子串替换，新域名包含旧域名时损坏配置
`core/handler.sh:5543-5556`

- old=example.com → new=myexample.com 时，会把 new 里的 `example.com` 再替换一遍变成 `mymyexample.com`，同时破坏 stream.conf 的 `ssl_preread` map 键。应为单词边界替换。

---

### 20. 空 XHTTP path 会生成 `location  {` 的坏站点配置
`core/handler.sh:5163-5164, 5277`

- `validate_xhttp_path` 对空串返回 0（`lib/protocols.sh:127`），`handler_change_domain` 只在非空时才校验；随后 `sed s|/yourpath|${XHTTP_PATH}|g` 把空串替换进去 → `location  {`，直到 nginx -t 才失败（此时站点文件已提交）。正常流程因 sni/cdn 走 `--path-required` 不会空，手改配置才触发。

---

### 21. cdn-down 变更失败回滚时删错证书目录并遗留新证书
`core/handler.sh:3449`

- 失败分支 `exec_ssl '--stop-renew' --domain=new '--delete-cert'` 删除的是 `${NGINX_CONFIG_PATH}/certs/<new>`，而 cdn-direct 证书实际部署在 `${CDN_XRAY_CERT_ROOT}/<component>/acme`（`get_cdn_direct_cert_dir`）。acme 记录被删、证书文件却遗留在错误路径，重试需重新签发。

---

### 22. `handler_reverse_share` 生成的桥接配置对 mKCP/SNI 等模式错误
`core/handler.sh:6051-6065`

- 只对 `xhttp` tag 生成 xhttp 出站；其他模式一律 `network:"raw"+REALITY`。但 `handler_reverse_config` 会把 reverse client 挂到**所有** vless inbound（含 KCP 的 mKCP、走 unix socket 的 SNI），生成的 bridge 出站连不上这些监听器 → 桥接不通。
- 另外 `handler_reverse_share` 对 hostname 目标把主机名塞进 `finalRules[].ip`（`handler.sh:6101/5989`），而 Xray 的 `ip` 只接受 IP/CIDR；`check_reverse_target` 却明确允许 hostname → 校验通过但生成的配置不可用。

---

### 23. `handler_reverse_share` 缺失 `reverseUuid/ReverseTarget` 时输出字面 "null"
`core/handler.sh:5972-5973`

- `jq -r '.xray.reverseUuid'`（无 `// ""`）在字段缺失时输出 `"null"` 字符串，且仅检查 `.xray.reverse==1`。手改配置把 reverse 设为 1 而未设配套字段时，bridge 模板打印 `"id":"null"` 等坏 JSON，而非报错。

---

### 24. multi 路径把空的 `.xray.rules.reset`（默认 `""`）当 0 处理，与单协议路径不一致
`core/handler.sh:1858`

- 单协议路径用 `case`（`handler.sh:2307`）把 `""` 视为"保留模板规则"；multi 路径用 `[[ "" -eq 0 ]]`（算术把空当 0）→ 若 `.rules` 为空数组，会把刚建的 `[api, private-ip]` 基座规则清空，丢失 api 路由与 `geoip:private` 反 SSRF 阻断。正常种子配置 `.rules` 非空，故为潜在缺陷。

---

### 25. `add_rule` 在 `handler_xray_config` 中途把不完整配置写盘、且吞掉校验失败
`core/handler.sh:1246, 2314-2316`

- reset=1 时对 bt/cn/ad 每个规则都 `write_xray_runtime_config`（含 `xray run -test`）+ `sleep 2`，此时 anti-steal 域名、WARP 出站、LAN 尚未应用；若中途被杀，落盘的是"合法但不完整"的配置（重启后 anti-steal 无域名、warp 出站缺失）。
- 且 `[[ ... ]] && add_rule ...` 链中 `add_rule` 返回 1 被吞掉，失败被当成功。

---

### 26. `SERVER_NAMES/SHORT_IDS` 用 `jq -r` 读，缺键时得到字符串 `"null"` 写入配置
`core/handler.sh:2098-2100, 2269-2285`

- `--argjson serverNames "null"` → `realitySettings.serverNames = null`，`xray run -test` 失败。正常流程 `handler_script_config` 总会写入这些键，仅手改/旧 schema 配置触发。

---

### 27. WARP socks 地址未校验/未加 IPv6 括号，多网卡容器 IP 拼接成坏 JSON
`core/handler.sh:2338`

- `get_container_ip` 用 `{{range ...}}{{.IPAddress}}{{end}}`，容器挂多网络时无分隔符拼接（`172.17.0.2172.18.0.3`）、IPv6 不带 `[]`；`jq --argjson` 解析失败则 `XRAY_CONFIG` 被置空、应用中止。

---

### 28. `handler_restart` 仅当 XHTTP path 变化才重启 nginx，已停止的 nginx 不会被拉回
`core/handler.sh:4150`

- `NGINX_CONFIG_CHANGED==0` 时不碰 nginx；SNI/CDN(nginx) 模式的公网 443 由 nginx 提供，若 nginx 被 `systemctl stop`（或崩溃）而 xhttp path 没变，重启 Xray 后节点仍不可达，脚本却报成功。

---

### 29. 死代码/不可达分支

| 位置 | 说明 |
|---|---|
| `handler.sh:6200` | `--quick` 全仓库无调用者（且若手动调用会因没跑 `handler_read_xray_config` 而 CONFIG_DATA 全空、全部走随机默认） |
| `menu.sh:528` + `menu.sh:487` | `menu_full_installation`（`--full`）无任何调用者，其空输入默认分支同样不可达 |
| `main.sh:834-837` | `processes_xray` 的 `is_exec='n'` 分支无调用者（`processes_index:1064` 从不传参） |

---

### 30. `print_status` 对缺失 key 显示字面 `"null"`
`core/menu.sh:430-445`

- `.xray.version`/`.xray.tag` 用裸 `jq -r`，缺键得 `"null"` 且 `[[ "null" ]]` 为真 → 状态栏绿字显示 `Xray : null` / `CONFIG : null`，而非"未安装/未配置"（`REVERSE_STATUS`/`LAN_STATUS` 用了 `// 0` 是正确的对照）。

---

### 31. HY2 分享链接缺 `sni` 参数
`core/share.sh:739`

- `hy2CertDomain` 为空时链接 `hysteria2://auth@IP:443/?insecure=0` 无 `&sni=`，客户端用公网 IP 作 serverName，TLS 校验失败且无提示（正常流程会设置该字段，手改/旧配置才触发）。

---

### 32. `is_valid_ipv6_literal` 接受畸形 `1::2:`
`core/share.sh:217-231`

- 压缩分支只拒绝三连冒号，不拒绝"压缩 + 尾冒号"；`1::2:` 被判合法。且 IPv4-mapped 分支把 IPv4 尾部替换成 `:0:0`，丢弃真实数值（组数仍凑巧正确）。仅影响 `resolve_public_host` 对 ipify 输出做校验，影响面小。

---

### 33. `generate_random` 取模有偏差
`core/generate.sh:60`

- `random % range` 对 32 位随机数，低 `2^32 % range` 个余数多出现一次；当前调用点（端口/长度）偏差 ~1e-9，实际无碍，但数学上存在。

---

### 34. `check_reverse_target` 不支持 IPv6
`core/check.sh:765`

- 正则只允许 `host:port`（单冒号），`[::1]:8080` 或 `fd00::5:8080` 永远校验失败 → IPv6 内网服务无法配置，用户困在输入循环里。

---

### 35. install.sh 状态配置里保存的非法 `.path` 会让脚本每次都直接报错退出
`install.sh:850`

- `choose_project_root` 对保存的 `.path`（如 `/`、`/opt`、含换行）`normalize_project_root` 返回 1 → `_error path_invalid`，用户每次运行都进不了菜单，唯一出路是 `-d` 或手改配置，而错误信息并未提示。

---

### 36. install.sh 内联 `write_config` 后备实现非原子、无 JSON 校验
`install.sh:83-92`

- 当 `lib/common.sh` 不在旁边时用 `echo > file` 直接截断写、跳过校验；更新事务（install.sh:711）与 `.path/.language` 写回会用这个后备，磁盘满时可能截断损坏状态文件。

---

### 37. install.sh 状态配置缺失 `.language` 键时语言菜单永不显示
`install.sh:879`

- `jq -r '.language'` 缺键返回 `"null"`（非空），`[[ -z "${lang}" ]]` 为假 → 从不进入选语言分支，用户被锁在默认中文（仅仓库自带 config 有 `"language":""` 才正常）。

---

## 四、服务层（nginx / ssl / docker / geodata）

### 38. nginx 更新备份用"日期"作后缀，同日两次更新互相覆盖
`service/nginx.sh:442, 878`

- `backup_files` 与 `source_update` 的二进制备份都用 `_$(date +%F)`；而 nginx 更新本身有每日 cron（`handler_nginx_cron` 03:00），同日再手动跑一次就把第一次的备份覆盖，回滚拿不到旧二进制。

---

### 39. nginx 平滑升级 `kill -USR2 $(cat /run/nginx.pid)` 无存在性检查
`service/nginx.sh:893`

- `prebuilt_install` 写入的最小 nginx.conf **没有 `pid` 指令**，PID 写在 `/usr/local/nginx/logs/nginx.pid`；此时 `--update` 会 `cat /run/nginx.pid` 失败、`kill -USR2` 无参数报错，却打印"no_old_process"并返回 0——新版二进制未被加载，升级"看似成功"。

---

### 40. nginx `cmd_exists` 的分支是死代码
`service/nginx.sh:183`

- `eval type type` 永远成功，`elif command`/`else which` 永不执行；且 `command`（无参数）是非法内建调用。lib/common.sh 的正确实现是 `command -v`。

---

### 41. nginx `_install` CentOS 分支的已装包快照过期，导致重复/错源安装
`service/nginx.sh:320`

- `installed_packages="$(dnf list installed)"` 在循环前只取一次；CentOS 9 分支前面用 remi 装的 `GeoIP-devel` 在循环里又被默认源装一遍，可能与预期版本冲突。

---

### 42. geodata.sh 的 `set -e` 使 `if [ $? -ne 0 ]` 变成不可达死代码
`tool/geodata.sh:3, 13-23`

- `set -e` 下 curl 失败直接退出，后续清理与错误提示永远不会执行，留下残缺 `.new` 文件且无诊断；cron 调用 `>/dev/null 2>&1` 更完全掩盖失败。

---

### 43. geodata.sh 非原子交换 .dat 文件
`tool/geodata.sh:25-28`

- 先 `rm -f geoip.dat geosite.dat` 再逐个 mv；中断或第二个 mv 失败会留下缺失的 `geosite.dat`，当前 Xray 靠内存副本存活，但下次启动直接失败。

---

### 44. docker `enable_warp` 存在竞态 / 已运行时不输出 IP
`service/docker.sh:297`

- `docker run -d` 后立即 `docker inspect` 取 IP，可能为空，`handler_warp` 因 `[[ -n ]]` 判定失败；且容器已在运行时（配置与容器状态不一致）整个 `if` 被跳过、函数无输出，重开 WARP 会误报失败。无等待/重试。

---

### 45. docker `clean_container_logs` 命令替换未加引号
`service/docker.sh:633`

- `truncate -s 0 $(docker inspect ...)` 容器不存在时 `truncate` 缺文件操作数报错，`handler_reset_warp` 把"容器已被手动删"当成硬失败。

---

### 46. ssl `check_certificate_status` 只匹配 acme 列表主域名
`service/ssl.sh:787`

- awk 只比对 `$1`（Main_Domain）；对 SAN/别名域名、大小写变体查询会误报"无证书"，即便该域名在证书 SAN 中受保护。

---

## 五、补充说明

- 上表已合并复核中的重复项（anti-steal 两条、reverse-share hostname 两条），共约 **46 个独立问题**；其中 **第 2、3 条是人工核对补充发现**，8 个深审代理 + 对抗复核未覆盖。
- 第 2、3 条影响最大（SNI+CDN 无法配置、LAN 菜单完全不生效），修复前建议先确认是否为有意的"仅重配后生效"设计——从交互文案（"地点已添加/拓扑已变化"）看更像缺陷。
- 全文未改动任何代码文件；如需，可针对每条给出最小复现命令或修复建议（仅建议，不动代码）。

---

*生成方式：人工通读 + 8 路并行深审 + 60 条发现对抗性复核 → 49 条确认 + 人工补充 2 条。*
