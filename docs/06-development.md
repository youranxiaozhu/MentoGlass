# 源码构建、测试与维护

## 1. 环境

运行 App：Apple Silicon Mac、macOS 26+。构建：完整 Xcode、支持相关 SwiftUI API 的 macOS SDK。当前已验证的是 macOS 27 SDK；仅安装旧版 Command Line Tools 可能缺少 SwiftUI 或 Liquid Glass API。

检查工具：

```bash
xcode-select -p
xcrun --sdk macosx --show-sdk-path
xcrun swiftc --version
```

如果路径指向旧工具目录，请在 Xcode 设置里选择正确工具链，或按自己的安装路径设置 `DEVELOPER_DIR`。无需修改项目为全局关闭沙箱或系统安全检查。

## 2. 构建

```bash
git clone https://github.com/youranxiaozhu/MentoGlass.git
cd MentoGlass
bash app/build.sh
```

构建顺序：编译原生可执行文件 → 从 `Icon.swift` 生成图标 → 复制配置和组件 → ad-hoc 签名 → 原生自检 → shell 语法检查 → 严格签名核验 → 创建 ZIP。图标由源码生成，仓库不需要额外图标二进制。产物位于 `dist/`。自定义输出目录可使用：

```bash
MENTOGLASS_OUTPUT_DIR=/tmp/MentoGlass-output bash app/build.sh
```

目标架构写为 `arm64-apple-macosx26.0`。Intel Mac 不在当前产物支持范围内；项目没有承诺未经测试的通用二进制。

## 3. 离线测试

无需路由器、账号或网络接入，只使用 Python 标准库和本地 shell：

```bash
python3 app/tests/test_schedule.py
python3 app/tests/test_dualwan.py
python3 app/tests/test_wireless_region.py
python3 tools/audit-publication.py
```

双线路 12 项测试包括同网段隔离、无效 DHCP 信息、重复地址、进程／物理口故障选择、硬件加速开关、先新增后删除路由、DHCP 并发变化和接口 ARP 范围。区域 6 项测试覆盖保存、异步应用与回退等；计时脚本通过本地模拟多种到期和跳过情况。

GitHub Actions 只运行这些离线检查，不保存校园网或路由器密码，不接触你的路由器，也不以通过 CI 表示真实校园认证成功。原生 Mac 构建在本机验收，不由当前 Linux CI 代替。

## 4. 代码分工

| 文件 | 职责 |
| --- | --- |
| `app/App.swift` | App 生命周期、菜单、原生自检、可选验收入口 |
| `app/Views.swift` | SwiftUI 界面和操作确认 |
| `app/Model.swift` | 异步操作、界面状态、日志清理、显示密码计时 |
| `app/Backend.swift` | SSH、钥匙串、配置更新和主认证命令 |
| `app/Extensions.swift` | 密码编码、定时组件、无线区域和第二账号命令 |
| `app/mentoglass_schedule.sh` | 路由器持续计时，最短 24 小时 |
| `app/mentoglass_wireless_region.sh` | 两无线设备区域保存、应用与恢复 |
| `app/dualwan/dualwan.sh` | 接口检查、策略路由、防火墙、分流、NSS |
| `app/dualwan/dhcp-event.sh` | 独立 DHCP 的地址、策略表与租约 |

SSH 密码通过临时私有文件提供给系统 SSH；账号配置通过 SSH stdin 传输，不嵌入命令参数。首次信任主机后拒绝身份变化。支持旧 RSA 的兼容设置只用于此连接。

## 5. 可选实机验收入口

二进制包含 `--extensions-check` 与 `--dualwan-check` 等维护入口，会连接路由器并私下检查状态／密码格式。它们需要 `MENTOGLASS_TEST_PASSWORD` 环境变量，**不要在公开 CI、脚本或命令历史写真实密码**。普通用户按 App 教程即可，无需运行这些入口。

`--live-check` 还会发起普通外网连通性请求；`--configure-extensions` 会安装组件并修改设置。二者不是离线测试，不能为了“跑全测试”盲目执行。GitHub CI 不调用这些入口。

## 6. 分发与版本

优先分发从干净临时目录创建的 ZIP。某些 macOS 文件提供程序会给散装 App 添加 Finder 元数据；因此 ZIP 制作前的严格签名核验与解压后的检查更可靠。

ad-hoc 签名提供本地完整性校验，不是 Apple 公证。正式对外分发若需要 Developer ID 签名与公证，应由有相应资格和证书的维护者完成。不要把证书私钥、Apple 凭据或真实路由器密码提交到仓库。[Apple 官方说明](https://support.apple.com/102445)

更新版本时修改 `app/Info.plist`，同步教程和版本记录；再测试、构建和核验归档。路由器上已有控制脚本也需经过备份与版本对照，避免 App 与现场组件不一致。
