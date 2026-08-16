中文 | [English](/.github/README.en.md)

# Xray 管理脚本 :sparkles:

* 一个纯 Shell 编写的 Xray 管理脚本
* 可选配置:
  * mKCP (VLESS-mKCP-seed)
  * Vision (VLESS-Vision-REALITY)
  * XHTTP (VLESS-XHTTP-REALITY)
  * trojan (Trojan-XHTTP-REALITY)
  * Fallback (包含 VLESS-Vision-REALITY、VLESS-XHTTP-REALITY)
  * Hysteria2 (HY2 over QUIC + TLS)
  * Shadowsocks 2022 (TCP + UDP)
  * CDN 独立模式 (VLESS-XHTTP-TLS，不包含 REALITY)
  * SNI (包含 Vision_REALITY、XHTTP_REALITY、XHTTP_TLS)
  * 多节点组合配置
* 支持 VLESS Encryption（VLESS enc，ML-KEM-768 后量子密钥封装）可选启用
* REALITY 支持可选的 ML-DSA-65 后量子签名验证
* CDN 与 SNI 是两个独立安装模式：CDN 只部署 XHTTP over TLS，并可选择 Nginx 或 Xray 直接 TLS 低资源后端；SNI 才启用 REALITY 与 SNI 分流
* HY2 支持域名证书、短期 IP 证书和自定义证书，自定义证书会校验私钥及 SAN/CN
* SNI 分享链接实现了上下行分离(上行 xhttp+TLS+CDN | 下行 xhttp+Reality、上行 xhttp+Reality | 下行 xhttp+TLS+CDN)
   * CDN/SNI 的站点证书分别保存，均支持自动申请或自行填写证书路径；Xray 直连 CDN 与 HY2 还会按域名/IP、自动/自定义来源隔离证书目录，避免旧续签任务覆盖当前证书
   * CDN 可选配置第二个下行域名，实现两个 CDN 分别承载上行和下行连接
* Nginx 模板默认启用 limit.conf 基础防护（常见扫描与恶意 UA 拦截）
* 规则配置与自填:
  * 禁止 bittorrent 流量(可选)
  * 禁止回国 ip 流量(可选)
  * 屏蔽广告(可选)
  * 添加自定义 WARP Proxy 分流
  * 添加自定义屏蔽分流
* 开关 Cloudflare WARP Proxy( :whale: Docker 部署)
* 开关 geodata 自动更新功能
* 异地组网（路由型虚拟局域网）:
  * 使用 Xray 原生 TUN 与 VLESS 反向通道连接多个地点
  * 支持多个不重叠的 IPv4 私网网段和 Linux 本机/网关模式
  * 为每个地点生成独立凭据、受限路由和可部署的 systemd 配置包
* xray 端口默认与自填:
  * VLESS-mKCP: 随机生成
  * ALL-REALITY: 443
* UUID 默认与自填:
  * 随机生成
  * 自定义输入标准 UUID
  * 非标准 UUID 映射转化为 UUID
* kcp(seed) 和 trojan(password) 默认与自填:
  * 随机生成(格式: cw-GEMDYgwIV3_g#)
  * 自定义输入
* target 默认与自填:
  * 随机在 serverNames.json 中获取
  * 实现自填 target 的 TLSv1.3 与 H2 验证
  * 实现自填 target 的 serverNames 自动获取
* shortId 默认与自填:
  * 随机生成(默认两个 shortId 例如: 01234567, 0123456789abcdef)
  * 实现自填 shortId
  * 实现输入值为 0 到 8, 则自动生成对 0-16 长度的 shortId
  * 支持逗号分隔的多个值
* path 默认与自填:
  * 随机生成(格式: /8ugSUeNJ.9OEnTErb.dVZMUAFu)
  * 自定义输入(格式: /8ugSUeNJ, 加不加 `/` 都可以)

## 最新功能与流程调整

* Vision 安装会在下载和安装 Xray 前一次性收集路由/屏蔽选项、端口、UUID、目标、Short ID、VLESS Encryption、ML-DSA-65，以及首次安装时的 GitHub 加速选择；安装后阶段只消费已保存配置，不会再次读取输入。
* 多节点模式已完整支持中英文菜单和提示。VLESS Encryption 在第一个适用的 VLESS 节点处询问一次，ML-DSA-65 在第一个 REALITY 节点处询问一次；纯 HY2 配置不会显示无关的 VLESS Encryption 选项。
* VLESS Encryption 参数按实际入站生成。带 `fallbacks` 的公共 Vision 入站保持 `decryption: "none"`，分享链接不会错误携带 `encryption`；可用的 VLESS 入站仍会生成对应参数。
* ML-DSA-65 选择会写入脚本配置。已存在的完整密钥对会直接复用，服务端 Seed 不输出到安装日志，客户端 Verify 会加入 REALITY 分享链接。
* GitHub 加速选择会持久化供 Xray 下载阶段使用；独立执行安装命令且没有保存选择时，仍会提供交互式兜底询问。
* CDN、SNI 与 XHTTP 模板使用当前 XHTTP 会话 ID 字段 `sessionIDPlacement`，保持三种模式的会话参数一致。

## 问题

1. 如果安装成功，但无法使用，请检查服务器是否开启对应端口，可通过 `https://tcp.ping.pe/ip:port` 验证服务器端口是否开放。
2. CDN/SNI 自动申请证书时，请确保 VPS 的 HTTP(80) 与 HTTPS(443) 端口开放，并暂时关闭 CDN 代理。证书失败会立即中止，不会生成不可用配置。
3. HY2 使用 UDP；除开放所选 UDP 端口外，还需确认服务商安全组允许 UDP。
4. 选择自行填写证书路径时，请确保 fullchain/privkey 文件存在可读，否则流程会中止且不会自动回退到 ACME 申请。
5. CDN 的 Nginx 后端会重建托管站点；Xray 直连后端会停止并禁用 Nginx、移除其自动更新任务，由 Xray 直接监听 443，以节省低配 VPS 的内存和后台进程。
6. 上下行分离详情请看 [XHTTP: Beyond REALITY][XHTTP] 与 [xhttp 五合一配置][xhttp 五合一配置] 了解。
7. 使用 SNI 获取证书时遇到 【Could not get nonce, let's try again】 请查看 [ZeroSSL 状态页](https://status.zerossl.com/)，大概率是 ZeroSSL 的【Free ACME Service】处于 【Service disruption】或【Service outage】状态。
8. v2025.11.19 版本解决【开启 WARP 时没有设置日志限制，导致容器日志会一直叠加，最终占满硬盘空间】问题。
   1. 已启动 WARP 分流的用户可以在【管理配置】->【分流管理】中选择【重置 WARP Proxy】选项，该选项实现清空容器日志与重置 WARP Proxy。
   2. 已添加日志限制，如需使用 WARP 功能直接启用即可。
9. Xray 直连 CDN 要求 CDN 使用 HTTPS 回源（Cloudflare 为 Full 或 Full (strict)，不能使用 Flexible）；使用流式 XHTTP 时还需在 CDN 开启 HTTP/2/gRPC。建议在 VPS 防火墙/安全组中将源站 443 仅放行 CDN 回源 IP；该模式不提供伪装站点或 Cloudreve。
10. v2026.07.28 修复 CDN 路径未同步 Nginx、多节点纯 HY2 误显示 VLESS enc、HY2 证书失败后仍生成配置，以及 ACME 邮箱误校验、X25519 新版输出解析、服务失败后仍继续分享和脚本自更新误降级等安装流程问题。
11. v2026.08.16 修复 ACME ECC 证书列表解析、HY2/CDN 证书复用选择和重复申请失败问题；重新申请证书会强制使用 `--force`，复用证书则只重新部署已有 ACME 证书。
12. v2026.08.17 修复独立分享脚本未加载公网 IP 校验函数导致分享链接生成失败的问题，并修复 Xray 证书部署时错误调用不支持的 systemd reload。

## 分享链接

基于[VMessAEAD / VLESS 分享链接标准提案](https://github.com/XTLS/Xray-core/discussions/716)与[v2rayN](https://github.com/2dust/v2rayN)实现，如果其他客户端无法正常使用，请自行根据分享链接进行修改。

CDN 独立模式的配置字段为 `.nginx.cdn`（上行）和 `.nginx.cdnDown`（可选下行，空字符串表示关闭）。两个域名必须不同，并且都要回源到同一个 Xray XHTTP 入站；UUID、path 和 mode 保持一致。旧配置缺少 `cdnDown` 时会按空值处理，不需要迁移。

```json
{
  "nginx": {
    "cdn": "upload-cdn.example.com",
    "cdnDown": "download-cdn.example.net"
  },
  "xray": {
    "path": "/same-xhttp-path",
    "xhttpMode": "packet-up"
  }
}
```

填写 `cdnDown` 后，CDN 分享链接仍以 `.nginx.cdn` 作为 `address`、`serverName` 和 `host`，并在 URL 编码的 XHTTP `extra` 中生成 `downloadSettings`。下行设置的 `address`、`serverName`、`host` 来自 `.nginx.cdnDown`，使用 443/TLS/XHTTP、H2 ALPN、Chrome 指纹，并复用相同的 path 和 mode；现有 XHTTP 混淆字段会与它合并。没有下行域名时不会生成该字段，继续保持单 CDN 链接。

`auto` 模式仍然可用，但它不保证客户端建立真正独立的上下行连接；需要明确上下行分离时优先选择 `packet-up` 或 `stream-up`，`stream-one` 不保证形成独立连接。

Nginx 后端会为两个域名生成各自的 443 TLS 站点，两个站点使用相同的 XHTTP path、伪装站点和 Unix socket。Xray 直连后端只保留一个 XHTTP TLS 入站，并在同一个 `tlsSettings.certificates` 数组中写入一套或两套证书，由 SNI 选择证书。两侧可分别申请证书或分别填写自定义证书；同一张覆盖两个域名的证书可以复用。CDN 必须使用 HTTPS 回源（Cloudflare 使用 Full 或 Full (strict)，不能使用 Flexible）。

证书元数据分别保存在 `.nginx.certificates.cdn` / `.nginx.certificates.cdnDown`，以及直连后端的 `.xray.cdnCertHostname/Source/Fullchain/Privkey` / `.xray.cdnDownCertHostname/Source/Fullchain/Privkey`。清除下行域名时会同时清理对应站点、元数据和自动续签任务。

SNI 配置中，CDN 的分享链接 Alpn 默认为 H2，如有 H3 需求，请自行在客户端修改。

## 如何使用

* 获取

  ```sh
  wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/haiyan1301/Xray-script/main/install.sh
  ```

* 使用
  * 启动界面

    ```sh
    bash ${HOME}/Xray-script.sh
    ```

  * 直接安装指定模式

    ```sh
    bash ${HOME}/Xray-script.sh --vision
    bash ${HOME}/Xray-script.sh --hy2
    bash ${HOME}/Xray-script.sh --cdn
    bash ${HOME}/Xray-script.sh --sni
    bash ${HOME}/Xray-script.sh --multi
    ```

    其余可用参数：`--xhttp`、`--trojan`、`--fallback`、`--ss2022`、`--mkcp`。

  * 管理异地组网

    ```sh
    bash ${HOME}/Xray-script.sh --lan
    ```

    Hub 初始化后至少添加两个地点，再分别导出地点端部署包。地点端需要支持 TUN 的 Xray-core、`jq`、`iproute2`；网关模式还需要 `iptables`。该功能只添加远端私网路由，不修改默认路由，不支持二层广播、mDNS 或网上邻居发现。

* 快速启动(界面)

  ```sh
  wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/haiyan1301/Xray-script/main/install.sh && bash ${HOME}/Xray-script.sh
  ```

## 脚本界面

```sh
 __   __  _    _   _______   _______   _____  
 \ \ / / | |  | | |__   __| |__   __| |  __ \ 
  \ V /  | |__| |    | |       | |    | |__) |
   > <   |  __  |    | |       | |    |  ___/ 
  / . \  | |  | |    | |       | |    | |     
 /_/ \_\ |_|  |_|    |_|       |_|    |_|     

Copyright (C) zxcvos | https://github.com/zxcvos/Xray-script

-------------------------------------------
Xray       : v25.7.26
CONFIG     : VLESS-Vision-REALITY
WARP Proxy : 已启动
-------------------------------------------

--------------- Xray-script ---------------
 Version      : v2025-07-25
 Description  : Xray 管理脚本
----------------- 装载管理 ----------------
1. 安装或重装节点
2. 仅更新 Xray 内核
3. 卸载
----------------- 操作管理 ----------------
4. 启动
5. 停止
6. 重启
----------------- 配置管理 ----------------
7. 分享链接与二维码
8. 信息统计
9. 管理配置
-------------------------------------------
0. 退出
```

## 已测试系统

| Platform | Version    |
| -------- | ---------- |
| Debian   | 10, 11, 12 |
| Ubuntu   | 20, 22, 24 |
| CentOS   | 7, 8, 9    |
| Rocky    | 8, 9       |

以上发行版均通过 Vultr 测试安装。

其他 Debian 基系统与 Red Hat 基系统可能能用，但未测试过，可能存在问题。

## 安装时长说明

CDN/SNI 的域名和证书可在「管理配置 -> CDN / SNI 站点管理」中维护；伪装站点仅在 Nginx 后端提供。低资源模式可重新配置后端或单独续签/加载 Xray 证书。

更换为非 CDN/SNI 协议后，Nginx 将停止服务但继续保留；切换到 CDN 的 Xray 直连后端时也会停止并禁用 Nginx。

### 安装时长参考

安装流程：选择协议 -> 一次性输入路由/屏蔽、端口、UUID/Short ID、VLESS Encryption、ML-DSA-65 与首次安装 GitHub 加速等适用参数 -> CDN 选择 Nginx 或 Xray 直连后端 -> 安装或复用 Xray -> 按已保存选择生成或复用密钥 -> 仅 Nginx 后端选择伪装站点并安装/复用 Nginx -> 配置并验证证书 -> 生成并校验配置 -> 启动服务 -> 输出分享链接。

**这是一台单核1G的服务器的平均安装时长，仅供参考：**

| 项目                | 时长      |
| ------------------- | --------- |
| 更新系统管理包      | 0-10分钟  |
| 安装依赖            | 0-5分钟   |
| 安装Docker          | 1-2分钟   |
| 安装Cloudreve       | 3-5分钟   |
| 安装Cloudflare-warp | 3-5分钟   |
| 安装Xray            | <半分钟   |
| 安装Nginx           | 13-15分钟 |
| 申请证书            | 1-2分钟   |
| 配置文件            | <半分钟  |

### Nginx 安装方式

默认下载预编译版本，也可在安装时选择本地源码编译。源码编译耗时更长，但可针对当前系统构建。

编译相比直接安装二进制文件的优点有：

1. 运行效率高 (编译时采用了-O3优化)
2. 软件版本新

缺点就是编译耗时长。

## 安装位置

**Xray-script:** `/usr/local/xray-script`

**Nginx:** `/usr/local/nginx`

**Cloudreve:** `$HOME/.xray-script/docker/cloudreve`

**Cloudflare-warp:** `$HOME/.xray-script/docker/warp`

**Xray:** 见 **[Xray-install](https://github.com/XTLS/Xray-install)**

## 依赖列表

使用 CDN/SNI 配置时，脚本可能自动安装以下依赖：
| 用途                            | Debian基系统                         | Red Hat基系统       |
| ------------------------------- | ------------------------------------ | ------------------- |
| yumdb set(标记包手动安装)       |                                      | yum-utils           |
| dnf config-manager              |                                      | dnf-plugins-core    |
| IP 获取                         | iproute2                             | iproute             |
| DNS 解析                        | dnsutils                             | bind-utils          |
| wget                            | wget                                 | wget                |
| curl                            | curl                                 | curl                |
| wget/curl https                 | ca-certificates                      | ca-certificates     |
| kill/pkill/ps/sysctl/free       | procps                               | procps-ng           |
| epel源                          |                                      | epel-release        |
| epel源                          |                                      | epel-next-release   |
| remi源                          |                                      | remi-release        |
| 防火墙                          | ufw                                  | firewalld           |
| **编译基础：**                  |                                      |                     |
| 下载源码文件                    | wget                                 | wget                |
| 解压tar源码文件                 | tar                                  | tar                 |
| 解压tar.gz源码文件              | gzip                                 | gzip                |
| gcc                             | gcc                                  | gcc                 |
| g++                             | g++                                  | gcc-c++             |
| make                            | make                                 | make                |
| **acme.sh依赖：**               |                                      |                     |
|                                 | curl                                 | curl                |
|                                 | openssl                              | openssl             |
|                                 | cron                                 | crontabs            |
| **编译openssl：**               |                                      |                     |
|                                 | perl-base(包含于libperl-dev)         | perl-IPC-Cmd        |
|                                 | perl-modules-5.32(包含于libperl-dev) | perl-Getopt-Long    |
|                                 | libperl5.32(包含于libperl-dev)       | perl-Data-Dumper    |
|                                 |                                      | perl-FindBin        |
| **编译Brotli：**                |                                      |                     |
|                                 | git                                  | git                 |
|                                 | libbrotli-dev                        | brotli-devel        |
| **编译Nginx：**                 |                                      |                     |
|                                 | libpcre2-dev                         | pcre2-devel         |
|                                 | zlib1g-dev                           | zlib-devel          |
| --with-http_xslt_module         | libxml2-dev                          | libxml2-devel       |
| --with-http_xslt_module         | libxslt1-dev                         | libxslt-devel       |
| --with-http_image_filter_module | libgd-dev                            | gd-devel            |
| --with-google_perftools_module  | libgoogle-perftools-dev              | gperftools-devel    |
| --with-http_geoip_module        | libgeoip-dev                         | geoip-devel         |
| --with-http_perl_module         |                                      | perl-ExtUtils-Embed |
|                                 | libperl-dev                          | perl-devel          |

## 致谢

[Xray-core][Xray-core]

[REALITY][REALITY]

[XHTTP: Beyond REALITY][XHTTP]

[integrated-examples][lxhao61/integrated-examples]

[xhttp 五合一配置][xhttp 五合一配置]

[部署 Cloudflare WARP Proxy][haoel]

[cloudflare-warp 镜像][e7h4n]

[V2Ray 路由规则文件加强版][v2ray-rules-dat]

[kirin10000/Xray-script][kirin10000/Xray-script]

[Cloudreve][cloudreve]

**此脚本仅供交流学习使用，请勿使用此脚本行违法之事。网络非法外之地，行非法之事，必将接受法律制裁。**

[Xray-core]: https://github.com/XTLS/Xray-core (THE NEXT FUTURE)
[REALITY]: https://github.com/XTLS/REALITY (THE NEXT FUTURE)
[XHTTP]: https://github.com/XTLS/Xray-core/discussions/4113 (XHTTP: Beyond REALITY)
[lxhao61/integrated-examples]: https://github.com/lxhao61/integrated-examples (以 V2Ray（v4 版） 或 Xray、Nginx 或 Caddy（v2 版）、Hysteria 等打造常用科学上网的优化配置及最优组合示例，且提供集成特定插件的 Caddy（v2 版） 文件，分享给大家食用及自己备份。)
[xhttp 五合一配置]: https://github.com/XTLS/Xray-core/discussions/4118 (xhttp 五合一配置 \( reality 直连与过 CDN 共存, 附小白可抄的配置\))
[haoel]: https://github.com/haoel/haoel.github.io#943-docker-%E4%BB%A3%E7%90%86 (使用 Docker 快速部署 Cloudflare WARP Proxy)
[e7h4n]: https://github.com/e7h4n/cloudflare-warp (cloudflare-warp 镜像)
[v2ray-rules-dat]: https://github.com/Loyalsoldier/v2ray-rules-dat (V2Ray 路由规则文件加强版)
[kirin10000/Xray-script]: https://github.com/kirin10000/Xray-script (kirin10000/Xray-script)
[cloudreve]: https://github.com/cloudreve/cloudreve (cloudreve)
