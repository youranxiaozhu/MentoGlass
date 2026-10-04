# MentoGlass

原生 macOS 校园网认证管理器，使用 SwiftUI 与 Liquid Glass，通过局域网 SSH 管理路由器上的 MentoHUST。

**版本：1.3.1 · Apple Silicon · macOS 26 及以上**。开发与本地验收环境为 macOS 27。运行 App 不需要 Python、网页服务器或额外运行库。

> 本项目管理**已经部署的 MentoHUST**，不是刷机工具或通用校园网破解工具。当前路由器控制逻辑适配小米 AX3000 **RA80、原厂 1.0.58 / Linux 4.4.60** 的特定部署。不要把它当作 AX3000T、AX3000 NE 或所有 OpenWrt 路由器的通用安装包。

## 功能

| 页面 | 可以做什么 |
| --- | --- |
| 概览 | 查看认证、WAN 地址与设备运行时间；手动检测外网及 DNS；重新认证 |
| 认证管理 | 修改账号和认证参数；启停认证；管理认证守护；定时重新认证；按需显示密码 |
| 双线路 | 管理第二个授权账号；按新连接进行 1:1 IPv4 分流；开关已验证的 NSS 硬件加速 |
| 运行日志 | 读取、筛选、导出日志，隐藏常见密码字段 |
| 连接设置 | SSH 与可选钥匙串保存；状态刷新；固定已运行的 160MHz；无线国家／地区 |

密码显示在 30 秒后、切换页面或关闭窗口时自动隐藏。定时认证运行在路由器上，Mac 睡眠或 App 关闭不影响计时。

## 从哪里开始

1. 阅读 [安装与首次连接](docs/01-install.md)，确认 Mac 和路由器符合条件。
2. 按 [路由器部署前提](docs/02-router-preparation.md) 检查已有认证组件。没有这些组件时，先完成适合本校与固件的 MentoHUST 部署。
3. 使用 [日常操作教程](docs/03-usage.md) 管理认证、计时和密码。
4. 已获得两个账号使用授权且学校允许同时接入时，再阅读 [双线路适配与回退](docs/04-dual-wan.md)。

其他教程：[无线与区域](docs/05-wireless.md) · [源码构建](docs/06-development.md) · [故障排查](docs/07-troubleshooting.md) · [验证范围](docs/08-validation.md)。

## 本机编译

安装完整 Xcode，并选择包含 macOS 26+ SwiftUI API 的 SDK。已验证的构建使用 macOS 27 SDK。

```bash
git clone https://github.com/youranxiaozhu/MentoGlass.git
cd MentoGlass
bash app/build.sh
open dist/MentoGlass.app
```

产物位于 `dist/`：`MentoGlass.app` 与 `MentoGlass.zip`。构建会执行原生自检和本地 ad-hoc 签名。该签名不等于 Apple Developer ID 签名或公证；其他 Mac 下载后可能受到 Gatekeeper 检查。详见 [构建与分发说明](docs/06-development.md)。

## 重要边界

- 两账号分流提高的是**多个连接的总吞吐潜力**，不把一条 TCP 连接合并为双倍带宽；不实现 IPv6 分流。
- 原有连接保留出口，真实断线后可能仍需应用自行重连。维护任务检查本地进程、物理链路和租约，不能证明端到端互联网可用。
- 硬件加速主要减少转发 CPU 开销，不能突破账号、线缆或上游端口限速。默认仅允许有实机验证标记的设备启用双线路 NSS 加速。
- Wi‑Fi 6 不代表 6GHz。AX3000 RA80 只有 2.4GHz 与 5GHz；改国家区域不能增加射频硬件。
- 160MHz 仍受雷达保护约束。区域应匹配实际使用地点，项目不关闭 DFS 或绕过雷达检测。
- 定时认证不是实时断网重连；间隔为 24–168 小时，初次安装默认关闭，只作用于第一账号。
- 自检和持续维护不扫描校园网、不测速压测、不做认证洪泛；手动外网检测只进行少量普通 ICMP／DNS 请求。

## 仓库内容

```text
app/                   原生 App、内置路由器脚本与离线测试
docs/                  安装、使用、适配、排错、验收教程
tools/check-router.sh  在自己的路由器执行的只读前提检查
tools/audit-publication.py  发布内容隐私检查
.github/workflows/     离线测试，不接触路由器或校园网
```

真实账号、密码、认证二进制、现场日志、路由器配置、SSH 主机记录和个人工作目录均不随仓库发布。测试中的地址是构造的私有网段样例；测试密码是刻意设置的假数据。

## 许可证与第三方组件

本仓库尚未指定开源许可证；源码公开不自动授予任意再分发许可。MentoHUST、路由器固件及第三方二进制的权利与许可由其各自项目决定。本仓库不分发原有 MentoHUST 二进制，也不分发个人账号或其配置。

## 参考资料

- [Apple：为自定义视图应用 Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [小米：AX3000 双频硬件规格](https://www.mi.com/sg/product/xiaomi-mesh-system-ax3000/specs/)
- [工信部：相关频段与 DFS 要求](https://www.miit.gov.cn/zwgk/zcwj/wjfb/tz/art/2021/art_e4ae71252eab42928daf0ea620976e4e.html)

