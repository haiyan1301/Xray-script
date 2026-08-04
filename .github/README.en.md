<!-- Translated by AI -->
[中文](/README.md) | English
# Xray Management Script :sparkles:

* A pure Shell-written Xray management script for Xray
* Optional configurations:
  * mKCP (VLESS-mKCP-seed)
  * Vision (VLESS-Vision-REALITY)
  * XHTTP (VLESS-XHTTP-REALITY)
  * trojan (Trojan-XHTTP-REALITY)
  * Fallback (includes VLESS-Vision-REALITY, VLESS-XHTTP-REALITY)
  * Hysteria2 (HY2 over QUIC + TLS)
  * Shadowsocks 2022 (TCP + UDP)
  * CDN-only mode (VLESS-XHTTP-TLS, without REALITY)
  * SNI (includes Vision_REALITY, XHTTP_REALITY, XHTTP_TLS)
  * Multi-node composite configuration
* Optional VLESS Encryption (VLESS enc with post-quantum ML-KEM-768 key encapsulation)
* Optional ML-DSA-65 post-quantum signature verification for REALITY
* CDN and SNI are separate modes: CDN deploys XHTTP over TLS with either an Nginx backend or a low-resource direct Xray TLS backend; SNI enables REALITY and SNI traffic splitting
* HY2 supports domain, short-lived IP, and custom certificates; custom certificates are checked against their key and SAN/CN
* SNI share links implement bidirectional separation (upstream: xhttp+TLS+CDN | downstream: xhttp+Reality, upstream: xhttp+Reality | downstream: xhttp+TLS+CDN)
* CDN and SNI certificates are stored independently; direct Xray CDN and HY2 additionally isolate certificate directories by hostname/IP and automatic/custom source so stale renewal hooks cannot overwrite the active pair
* CDN-only mode can use an optional second domain so separate CDNs carry uplink and downlink connections
* Rule configurations and custom entries:
  * Block BitTorrent traffic (optional)
  * Block China IP traffic (optional)
  * Ad blocking (optional)
  * Add custom WARP Proxy rules
  * Add custom block rules
* Cloudflare WARP Proxy toggle (🐳 Docker deployment)
* Geodata auto-update toggle
* Site-to-site routed virtual LAN:
  * Connects multiple sites with Xray's native TUN inbound and VLESS reverse channels
  * Supports non-overlapping private IPv4 CIDRs and Linux host/gateway modes
  * Generates isolated credentials, restricted routes, and a deployable systemd package for each site
* Xray ports default/fill:
  * VLESS-mKCP: Randomly generated
  * ALL-REALITY: 443
* UUID default/fill:
  * Randomly generated
  * Custom standard UUID input
  * Non-standard UUID mapping conversion
* kcp(seed) and trojan(password) default/fill:
  * Random generation (format: cw-GEMDYgwIV3_g#)
  * Custom input
* target default/fill:
  * Random selection from serverNames.json
  * TLSv1.3 and H2 validation for custom targets
  * Automatic serverNames acquisition for custom targets
* shortId default/fill:
  * Random generation (default two shortIds e.g.: 01234567, 0123456789abcdef)
  * Custom shortId input
  * Numeric input 0-8 generates 0-16 length shortIds
  * Comma-separated multiple values
* path default/fill:
  * Random generation (format: /8ugSUeNJ.9OEnTErb.dVZMUAFu)
  * Custom input (format: /8ugSUeNJ, with/without `/`)

## Recent Features and Flow Changes

* Vision collects routing/block choices, port, UUID, target, Short ID, VLESS Encryption, ML-DSA-65, and the first-install GitHub proxy choice before downloading or installing Xray. Post-install stages consume the saved configuration without reading input again.
* Multi-node mode now has complete Chinese and English menus and messages. VLESS Encryption is asked once at the first applicable VLESS node, while ML-DSA-65 is asked once at the first REALITY node. Pure HY2 configurations do not show unrelated VLESS Encryption prompts.
* VLESS Encryption parameters are generated per inbound. A public Vision inbound with `fallbacks` keeps `decryption: "none"`, so its share link does not incorrectly include `encryption`; eligible VLESS inbounds still receive the parameter.
* The ML-DSA-65 choice is persisted. Existing complete key pairs are reused, the server Seed is not printed in installation logs, and the client Verify value is included in REALITY share links.
* The GitHub proxy choice is persisted for the Xray download stage. A standalone install command still prompts when no saved choice is available.
* CDN, SNI, and XHTTP templates use the current XHTTP session ID field, `sessionIDPlacement`, keeping session parameters consistent across all three modes.

## Issues

1. If the installation is successful but does not work properly, please check whether the server port is open. You can verify port accessibility through `https://tcp.ping.pe/ip:port`
2. For automatic CDN/SNI certificates, open HTTP(80) and HTTPS(443) and temporarily disable CDN proxying. Certificate failure stops the flow before an unusable runtime config is generated
3. HY2 uses UDP. Open the selected UDP port in both the host firewall and provider security group
4. The Nginx CDN backend rebuilds its managed site. The direct Xray backend stops and disables Nginx, removes its auto-update job, then lets Xray listen on 443 to save memory and background processes
5. Direct Xray CDN requires an HTTPS origin mode (Cloudflare Full or Full (strict), never Flexible). Enable HTTP/2/gRPC at the CDN for streaming XHTTP, and restrict origin port 443 to CDN source IPs in the VPS firewall/security group where possible. This mode has no camouflage site or Cloudreve
6. For upstream/downstream separation details, see [XHTTP: Beyond REALITY][XHTTP] and [xhttp 五合一配置][xhttp 五合一配置]
7. When using SNI to obtain a certificate and encountering the error ["Could not get nonce, let's try again"], please check the [ZeroSSL Status Page](https://status.zerossl.com/) . It is highly likely that ZeroSSL's "Free ACME Service" is experiencing "Service disruption" or "Service outage"
8. Version v2025.11.19 resolves the issue where 【"WARP was enabled without log limits, causing container logs to accumulate continuously, eventually filling up disk space"】.
   1. Users who have already started WARP can go to 【"Manage Configuration"】 -> 【"Routing Management"】 and select the 【"Reset WARP Proxy"】 option. This option clears container logs and resets the WARP Proxy.
   2. Log limits have been added. To use the WARP feature, simply enable it directly.
9. Version v2026.07.28 fixes Nginx CDN path drift, VLESS enc prompts on pure-HY2 multi-node setups, config generation after HY2 certificate failure, ACME email validation, current X25519 output parsing, continuation after service failures, and accidental script self-update downgrades.

## Share Links

Based on [VMessAEAD / VLESS 分享链接标准提案](https://github.com/XTLS/Xray-core/discussions/716) and [v2rayN](https://github.com/2dust/v2rayN). Modify links manually if other clients have compatibility issues.

CDN-only mode uses `.nginx.cdn` for uplink and optional `.nginx.cdnDown` for downlink. The domains must differ and both CDN routes must reach the same Xray XHTTP inbound with the same UUID, path, and mode. A missing or empty `cdnDown` preserves the existing single-CDN behavior.

When `cdnDown` is set, the primary share-link address, SNI, and host still use `.nginx.cdn`. Its URL-encoded XHTTP `extra` gains a `downloadSettings` object whose address, SNI, and host use `.nginx.cdnDown`; it uses port 443, TLS, XHTTP, H2, the Chrome fingerprint, and the same path and mode. Existing XHTTP obfuscation fields are merged into the same object.

`auto` remains supported, but use `packet-up` or `stream-up` when independent uplink/downlink connections are required. `stream-one` does not guarantee separate connections. The Nginx backend creates one TLS site per domain and sends both to the same XHTTP Unix socket. The direct Xray backend keeps one inbound and places one or two certificates in its TLS certificate array for SNI selection. Custom certificates may be separate, or one certificate may be reused if it covers both domains.

Certificate metadata is stored separately under `.nginx.certificates.cdn` / `.nginx.certificates.cdnDown` and, for the direct backend, `.xray.cdnCertHostname/Source/Fullchain/Privkey` / `.xray.cdnDownCertHostname/Source/Fullchain/Privkey`. Clearing the downlink domain also removes its managed site, metadata, and renewal task.

In SNI configurations, CDN share links default Alpn to H2. For H3 requirements, modify client settings manually.

## Usage

* Download:
  ```sh
  wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/haiyan1301/Xray-script/main/install.sh
  ```
  
* Usage
  * Launch interface

    ```sh
    bash ${HOME}/Xray-script.sh
    ```

  * Install a specific mode directly

    ```sh
    bash ${HOME}/Xray-script.sh --vision
    bash ${HOME}/Xray-script.sh --hy2
    bash ${HOME}/Xray-script.sh --cdn
    bash ${HOME}/Xray-script.sh --sni
    bash ${HOME}/Xray-script.sh --multi
    ```

    Other flags: `--xhttp`, `--trojan`, `--fallback`, `--ss2022`, and `--mkcp`.

  * Manage site-to-site LAN

    ```sh
    bash ${HOME}/Xray-script.sh --lan
    ```

    Initialize the Hub, add at least two sites, and export each edge package. An edge requires Xray-core with TUN support, `jq`, and `iproute2`; gateway mode also requires `iptables`. Only declared remote private CIDRs are routed. Layer-2 broadcast, mDNS, and network-neighborhood discovery are not supported.

* Quick start (with interface)
  ```sh
  wget --no-check-certificate -O ${HOME}/Xray-script.sh https://raw.githubusercontent.com/haiyan1301/Xray-script/main/install.sh && bash ${HOME}/Xray-script.sh
  ```

## Script Interface

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
CONFIG     : VLESS-XHTTP-REALITY
WARP Proxy : Running
-------------------------------------------

--------------- Xray-script ---------------
 Version      : v2025-07-25
 Description  : Xray Management Script
----------------- Installation ----------------
1. Install or reconfigure a node
2. Update Xray core only
3. Uninstall
----------------- Operation -----------------
4. Start
5. Stop
6. Restart
----------------- Configuration -------------
7. Share links & QR codes
8. Statistics
9. Manage configuration
-------------------------------------------
0. Exit
```

## Tested Systems

| Platform | Version    |
| -------- | ---------- |
| Debian   | 10, 11, 12 |
| Ubuntu   | 20, 22, 24 |
| CentOS   | 7, 8, 9    |
| Rocky    | 8, 9       |

All tested on Vultr instances. Other Debian/Red Hat derivatives might work but are untested.

## Installation Time Notes

Manage CDN/SNI domains and certificates under `Manage Configuration -> CDN / SNI Site Management`. Camouflage content is available only with Nginx; direct mode can reconfigure the backend or renew/reload the Xray certificate.

When switching to a protocol other than CDN/SNI, Nginx stops but remains installed. Selecting the direct Xray CDN backend also stops and disables Nginx.

Installation flow: choose a protocol -> enter applicable routing/block, port, UUID/Short ID, VLESS Encryption, ML-DSA-65, and first-install GitHub proxy settings once -> choose the CDN backend when applicable -> install or reuse Xray -> generate or reuse keys from the saved choices -> only Nginx-backed modes choose camouflage content and install/reuse Nginx -> configure and verify certificates -> generate and validate the configuration -> start services -> print share links.

### Installation Time Reference (1CPU/1GB)

| Process                 | Duration           |
| ----------------------- | ------------------ |
| Update system packages  | 0-10 minutes       |
| Install dependencies    | 0-5 minutes        |
| Install Docker          | 1-2 minutes        |
| Install Cloudreve       | 3-5 minutes        |
| Install Cloudflare-warp | 3-5 minutes        |
| Install Xray            | < half a minute    |
| Install Nginx           | 13-15 minutes      |
| Issue certificates      | 1-2 minutes        |
| Configuration files     | < 100 milliseconds |

### Nginx Installation

The prebuilt package is the default. Local source compilation remains available during installation and takes longer.

The advantages of compiling include:

1. High runtime efficiency (optimized with -O3 during compilation)
2. Newer software versions

The drawback is that compilation takes a long time.

## Installation Paths


**Xray-script:** `/usr/local/etc/xray-script`

**Nginx:** `/usr/local/nginx`

**Cloudreve:** `$HOME/.xray-script/cloudreve`

**Cloudflare-warp:** `$HOME/.xray-script/cloudflare_warp`

**Xray:** See **[Xray-install](https://github.com/XTLS/Xray-install)**


## Dependencies

CDN/SNI configuration may install these dependencies:

| Purpose                                           | Debian-based Systems                        | Red Hat-based Systems |
| ------------------------------------------------- | ------------------------------------------- | --------------------- |
| yumdb set (mark packages for manual installation) |                                             | yum-utils             |
| dnf config-manager                                |                                             | dnf-plugins-core      |
| IP retrieval                                      | iproute2                                    | iproute               |
| DNS resolution                                    | dnsutils                                    | bind-utils            |
| wget                                              | wget                                        | wget                  |
| curl                                              | curl                                        | curl                  |
| wget/curl https                                   | ca-certificates                             | ca-certificates       |
| kill/pkill/ps/sysctl/free                         | procps                                      | procps-ng             |
| epel repository                                   |                                             | epel-release          |
| epel repository                                   |                                             | epel-next-release     |
| remi repository                                   |                                             | remi-release          |
| Firewall                                          | ufw                                         | firewalld             |
| **Compilation Basics:**                           |                                             |                       |
| Download source files                             | wget                                        | wget                  |
| Unzip tar source files                            | tar                                         | tar                   |
| Unzip tar.gz source files                         | gzip                                        | gzip                  |
| gcc                                               | gcc                                         | gcc                   |
| g++                                               | g++                                         | gcc-c++               |
| make                                              | make                                        | make                  |
| **acme.sh Dependencies:**                         |                                             |                       |
|                                                   | curl                                        | curl                  |
|                                                   | openssl                                     | openssl               |
|                                                   | cron                                        | crontabs              |
| **Compile openssl:**                              |                                             |                       |
|                                                   | perl-base (included in libperl-dev)         | perl-IPC-Cmd          |
|                                                   | perl-modules-5.32 (included in libperl-dev) | perl-Getopt-Long      |
|                                                   | libperl5.32 (included in libperl-dev)       | perl-Data-Dumper      |
|                                                   |                                             | perl-FindBin          |
| **Compile Brotli:**                               |                                             |                       |
|                                                   | git                                         | git                   |
|                                                   | libbrotli-dev                               | brotli-devel          |
| **Compile Nginx:**                                |                                             |                       |
|                                                   | libpcre2-dev                                | pcre2-devel           |
|                                                   | zlib1g-dev                                  | zlib-devel            |
| --with-http_xslt_module                           | libxml2-dev                                 | libxml2-devel         |
| --with-http_xslt_module                           | libxslt1-dev                                | libxslt-devel         |
| --with-http_image_filter_module                   | libgd-dev                                   | gd-devel              |
| --with-google_perftools_module                    | libgoogle-perftools-dev                     | gperftools-devel      |
| --with-http_geoip_module                          | libgeoip-dev                                | geoip-devel           |
| --with-http_perl_module                           |                                             | perl-ExtUtils-Embed   |
|                                                   | libperl-dev                                 | perl-devel            |

## Credits

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

**This script is for educational purposes only. Do not use it for illegal activities.**

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
