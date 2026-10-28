# 2026-10-28 检查与修复

本次修复版本为 `v2026.10.28`，针对日志中的 CDN 安装失败，并检查相关安装、更新、配置生成、分享和下载流程。

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

本次未连接用户的 VPS，未进行真实 ACME 签发、系统服务安装或 CDN 公网链路测试。旧版自选内核及客户端仍需支持所使用的协议字段。
