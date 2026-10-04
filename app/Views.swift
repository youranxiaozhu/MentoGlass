import SwiftUI
import AppKit
import Combine

private let accent = Color(red: 0.12, green: 0.45, blue: 0.95)

struct Surface<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.28), lineWidth: 1))
            .shadow(color: .black.opacity(0.035), radius: 18, y: 7)
    }
}

struct Pill: View {
    var text: String
    var color: Color = accent
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold))
        }.foregroundStyle(color).padding(.horizontal, 11).padding(.vertical, 7)
            .glassEffect(.regular.tint(color.opacity(0.07)), in: Capsule())
    }
}

struct GlassAction: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        if prominent {
            Button(action: action) { Label(title, systemImage: icon).padding(.horizontal, 7).padding(.vertical, 4) }
                .buttonStyle(.glassProminent).tint(accent).controlSize(.large)
        } else {
            Button(action: action) { Label(title, systemImage: icon).padding(.horizontal, 5).padding(.vertical, 4) }
                .buttonStyle(.glass).controlSize(.large)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: RouterModel
    @Environment(\.colorScheme) var scheme
    @State private var stopConfirmation = false
    @State private var regionApplyConfirmation = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.15 : 0.085),
                                    Color.cyan.opacity(0.045), Color.indigo.opacity(0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                Circle().fill(Color.cyan.opacity(0.075)).frame(width: 400, height: 400).blur(radius: 80)
                    .offset(x: g.size.width * 0.35, y: -240)
            }.allowsHitTesting(false)
            HStack(spacing: 0) {
                sidebar.frame(width: 212).padding(12)
                VStack(spacing: 0) {
                    header.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 20)
                    ScrollView {
                        Group {
                            switch model.section {
                            case .overview: overview
                            case .authentication: authentication
                            case .dualwan: dualwan
                            case .logs: logs
                            case .settings: settings
                            }
                        }.padding(.horizontal, 30).padding(.bottom, 24)
                    }
                    footer.padding(.horizontal, 30).padding(.vertical, 13)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 700)
        .alert("操作未完成", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("知道了", role: .cancel) { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
        .alert("停止主线路认证？", isPresented: $stopConfirmation) {
            Button("停止认证", role: .destructive) { model.perform("stop") }
            Button("取消", role: .cancel) { }
        } message: { Text("将停止主线路 MentoHUST，关闭它的守护和定时认证。第二线路单独控制；已开启分流且第二线路就绪时，新连接会转向第二线路。主 Wi-Fi 的本地管理仍可使用。") }
        .alert("重启无线并应用区域？", isPresented: $regionApplyConfirmation) {
            Button("重启无线并应用") { model.applyWifiRegion() }
            Button("取消", role: .cancel) { }
        } message: { Text("将应用已保存的 \(WirelessRegion.display(code: model.snapshot["WifiCountry1"])) 区域。Wi-Fi 会断开，DFS 信道可能需要等待雷达检测；请重新连接后刷新状态。请确保区域与实际使用地点一致。") }
        .onReceive(timer) { _ in
            if model.autoRefresh && model.connected && !model.busy { model.refresh() }
        }
        .onChange(of: model.connection.identity) { _, _ in model.connectionChanged() }
        .onChange(of: model.section) { _, _ in model.hideCampusPassword() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title.contains("校园网控制中心") { model.hideCampusPassword() }
        }
        .task { if model.anyCredentials { model.refresh() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "wifi").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [accent, .cyan], startPoint: .bottomLeading, endPoint: .topTrailing), in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: accent.opacity(0.2), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MentoGlass").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("校园网控制中心").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 15).padding(.top, 42).padding(.bottom, 30)
            Text("工作空间").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 22).padding(.bottom, 10)
            VStack(spacing: 5) {
                ForEach(Section.allCases) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { model.section = section }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.icon).font(.system(size: 16)).frame(width: 20)
                            Text(section.rawValue).font(.system(size: 13, weight: model.section == section ? .semibold : .medium))
                            Spacer()
                            if model.section == section { Circle().fill(accent).frame(width: 5, height: 5) }
                        }.foregroundStyle(model.section == section ? accent : .primary)
                            .padding(.horizontal, 15).padding(.vertical, 13).contentShape(RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain)
                        .background(model.section == section ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 13))
                        .accessibilityLabel(section.rawValue)
                }
            }.padding(.horizontal, 9)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Divider().opacity(0.5)
                HStack(spacing: 10) {
                    Image(systemName: "wifi.router").foregroundStyle(accent).font(.system(size: 21))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("小米 AX3000").font(.system(size: 12, weight: .semibold))
                        Text(model.connection.host).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(model.connected ? Color.green : Color.gray).frame(width: 5, height: 5)
                    Text(model.connected ? "局域网已连接" : "等待连接路由器").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(19)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 25))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.section.rawValue).font(.system(size: 29, weight: .bold))
                Text(model.section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
            GlassAction(title: model.connected ? "刷新状态" : "连接路由器", icon: model.connected ? "arrow.clockwise" : "link") {
                if model.anyCredentials { model.refresh() } else { model.section = .settings }
            }.disabled(model.busy)
        }
    }

    private var overview: some View {
        VStack(spacing: 18) {
            Surface {
                HStack(spacing: 22) {
                    ZStack {
                        Circle().fill(accent.opacity(0.06)).frame(width: 108, height: 108)
                        Circle().stroke(accent.opacity(0.14), lineWidth: 1).frame(width: 92, height: 92)
                        Image(systemName: "wifi.router.fill").font(.system(size: 39)).foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 11) {
                        Pill(text: model.connected ? "本地管理已就绪" : "开始连接", color: model.connected ? .green : accent)
                        Text(model.online == true ? "校园网当前可用" : model.connected ? "你的路由器，就在这里。" : "让校园网管理更简单。")
                            .font(.system(size: 23, weight: .semibold))
                        Text(model.connected ? "Wi-Fi 与网线均可管理；外网状态独立检测。" : "连接路由器主 Wi-Fi，填写 SSH 密码即可开始。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Divider().padding(.vertical, 18).opacity(0.5)
                GlassEffectContainer(spacing: 14) {
                    HStack(spacing: 12) {
                        GlassAction(title: model.snapshot.running ? "重新认证" : "启动认证", icon: "arrow.triangle.2.circlepath", prominent: true) {
                            model.perform(model.snapshot.running ? "restart" : "start")
                        }
                        GlassAction(title: "检测外网", icon: "globe") { model.testNetwork() }
                        Spacer()
                        Button("查看日志") { model.section = .logs; model.loadLogs() }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 12, weight: .medium))
                    }
                }.disabled(model.busy || !model.connected)
            }
            HStack(spacing: 14) {
                metric(icon: "server.rack", title: "认证进程", value: model.connected ? (model.snapshot.running ? "运行中" : "已停止") : "尚未读取", color: model.snapshot.running && model.connected ? accent : .secondary, detail: "进程状态不等于上网状态")
                metric(icon: "globe.asia.australia", title: "外网连通", value: model.online == nil ? "待检测" : model.online == true ? "可用" : "未通过", color: model.online == true ? .green : model.online == false ? .orange : .secondary, detail: model.networkCheckedAt.map { "检测于 " + $0.formatted(date: .omitted, time: .standard) } ?? "点击「检测外网」更新")
                metric(icon: "shield.lefthalf.filled", title: "认证守护", value: model.connected ? (model.snapshot.enabled ? "已开启" : "未开启") : "尚未读取", color: model.snapshot.enabled && model.connected ? accent : .secondary, detail: "当前守护负责维持进程存活")
            }
            HStack(alignment: .top, spacing: 16) {
                Surface {
                    cardTitle("网络信息", icon: "network")
                    infoRow("WAN 地址", model.connected ? model.wanIP : "—", mono: true)
                    infoRow("上游网关", model.snapshot["gateway"].isEmpty ? "—" : model.snapshot["gateway"], mono: true)
                    infoRow("设备运行", model.runtime)
                    infoRow("DNS 解析", model.dnsOK == nil ? "待检测" : model.dnsOK == true ? "正常" : "未通过")
                }
                Surface {
                    cardTitle("最近活动", icon: "clock")
                    if model.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("准备迎接第一次连接").font(.system(size: 13, weight: .medium))
                            Text("这里会记录连接、认证和检测结果。所有状态都来自你的路由器。")
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                        }.padding(.vertical, 12)
                    } else {
                        ForEach(model.activity.prefix(3)) { activity in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: activity.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(activity.success ? Color.green : Color.orange).font(.system(size: 13)).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.title).font(.system(size: 12, weight: .medium))
                                    Text(activity.date.formatted(date: .omitted, time: .standard)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(.vertical, 5)
                        }
                    }
                }
            }
            if model.configWarning { warning }
        }
    }

    private func metric(icon: String, title: String, value: String, color: Color, detail: String) -> some View {
        Surface(padding: 18) {
            HStack {
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 16))
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.system(size: 22, weight: .semibold)).foregroundStyle(color).padding(.top, 13)
            Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 5).lineLimit(2)
        }
    }
    private func cardTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).padding(.bottom, 14)
    }
    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default)).textSelection(.enabled)
        }.font(.system(size: 12)).padding(.vertical, 7)
    }
    private var warning: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text("发现现有 DHCP 配置异常").font(.system(size: 12, weight: .semibold))
                Text("路由器的 DHCP 命令缺少网卡参数，可能影响认证后获取 IP。此 App 不会自动覆盖这项配置。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            Spacer()
        }.padding(16).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: 18) {
            Surface {
                HStack {
                cardTitle("主线路认证控制", icon: "power")
                    Spacer()
                    Pill(text: model.snapshot.running && model.connected ? "运行中" : "未运行", color: model.snapshot.running && model.connected ? .green : .secondary)
                }
                HStack(spacing: 12) {
                    GlassAction(title: "重新认证", icon: "arrow.triangle.2.circlepath", prominent: true) { model.perform("restart") }
                    GlassAction(title: "启动", icon: "play.fill") { model.perform("start") }
                    GlassAction(title: "停止", icon: "stop.fill") { stopConfirmation = true }
                    Spacer()
                }.disabled(!model.connected || model.busy)
                Divider().padding(.vertical, 16).opacity(0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("认证守护").font(.system(size: 12, weight: .semibold))
                        Text("开启后会在进程退出时自动拉起。关闭守护不会停止当前认证。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.snapshot.enabled ? "关闭守护" : "开启守护") { model.perform(model.snapshot.enabled ? "disable" : "enable") }
                        .buttonStyle(.glass).disabled(!model.connected || model.busy)
                }
            }
            scheduleCard
            campusPasswordCard
            Surface {
                cardTitle("校园网账号与参数", icon: "person.crop.circle.badge.checkmark")
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                    GridRow {
                        field("校园网账号", hint: "从路由器读取") { TextField("输入账号", text: model.edited(\.account)) }
                        field("校园网密码", hint: "留空保留路由器现有密码") { SecureField("仅在修改密码时填写", text: model.edited(\.campusPassword)) }
                    }
                    GridRow {
                        field("WAN 网卡", hint: "当前设备通常为 eth0") { TextField("eth0", text: model.edited(\.nic)) }
                        field("认证模式", hint: "与校园网络协议一致") {
                            Picker("认证模式", selection: model.edited(\.authMode)) { Text("锐捷").tag("1"); Text("标准").tag("0"); Text("赛尔").tag("2") }.labelsHidden()
                        }
                    }
                    GridRow {
                        field("DHCP 方式", hint: "控制认证与 IP 获取顺序") {
                            Picker("DHCP 方式", selection: model.edited(\.dhcpMode)) { Text("认证后获取 IP").tag("2"); Text("认证前获取 IP").tag("3"); Text("二次认证").tag("1"); Text("不使用 DHCP").tag("0") }.labelsHidden()
                        }
                        field("失败等待（秒）", hint: "检测到失败后的重试等待") { TextField("15", text: model.edited(\.restartWait)) }
                    }
                    GridRow {
                        field("心跳间隔（秒）", hint: "向认证服务器发送心跳") { TextField("30", text: model.edited(\.echoInterval)) }
                        field("最大失败次数", hint: "0 表示持续重试") { TextField("0", text: model.edited(\.maxFail)) }
                    }
                }.disabled(!model.configurationLoaded || model.busy)
                Divider().padding(.vertical, 20).opacity(0.5)
                HStack {
                    Text("保存前会在路由器备份原配置。保存后需重新认证。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    GlassAction(title: "保存配置", icon: "checkmark", prominent: true) { model.saveConfig() }.disabled(!model.configurationLoaded || model.busy)
                }
            }
            if model.configWarning { warning }
        }
    }

    private var dualwan: some View {
        let installed = model.snapshot["DualInstalled"] == "yes"
        let ready = model.connected && model.snapshot["SecondReady"] == "yes"
        let enabled = model.snapshot["BalanceEnabled"] == "yes"
        let active = model.connected && model.snapshot["BalanceActive"] == "yes"
        let secondOnly = model.snapshot["BalanceMode"] == "second-only"
        let hardwareSupported = model.snapshot["HardwareAccelerationSupported"] == "yes"
        let hardwareEnabled = model.snapshot["HardwareAccelerationEnabled"] == "yes"
        return VStack(spacing: 18) {
            Surface {
                HStack {
                    cardTitle("两条校园网线路", icon: "arrow.triangle.branch")
                    Spacer()
                    Pill(text: active ? (secondOnly ? "仅第二线路" : "分流中") : "未分流", color: active ? .green : .secondary)
                }
                infoRow("主线路 · WAN", model.connected ? model.wanIP : "未连接路由器")
                infoRow("第二线路 · LAN1", ready ? model.snapshot["SecondIP"] : "尚未就绪")
                infoRow("第二账号", model.secondAccount.isEmpty ? "尚未读取" : model.secondAccount)
                Divider().padding(.vertical, 16).opacity(0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("双线路分流").font(.system(size: 13, weight: .semibold))
                        Text(secondOnly ? "主线路暂不可用，新连接使用第二线路。" : "新连接按 1:1 选择线路，同一连接保持同一出口。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("双线路分流", isOn: Binding(get: { enabled }, set: { model.performDual($0 ? "balance-on" : "balance-off") }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!model.connected || model.busy || !installed || (!ready && !enabled))
                }
                Text(enabled && !active ? "分流已设定，正在等待第二线路就绪。" : "适合多设备、多任务同时上网；单条下载连接仍只使用一条线路。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
                Divider().padding(.vertical, 16).opacity(0.5)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("双线路硬件加速").font(.system(size: 13, weight: .semibold))
                        Text(hardwareSupported ? "减轻转发时的 CPU 负担，实际提速取决于负载。" : "这台路由器尚未验证双线路加速兼容性。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("双线路硬件加速", isOn: Binding(get: { hardwareEnabled }, set: { model.performDual($0 ? "hardware-on" : "hardware-off") }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!model.connected || model.busy || !hardwareSupported || !active)
                }
                if active && hardwareEnabled {
                    Text(model.snapshot["HardwareAccelerationMode"] == "2" ? "硬件加速已开启 · 当前加速连接：\(model.snapshot["HardwareAcceleratedConnections"])" : "已设定硬件加速，正在等待生效。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
                }
                Text("LAN1 已改作第二条校园网入口，请勿在这里连接普通内网设备。两条入口当前均为 100 Mbps 链路。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            }
            Surface {
                cardTitle("第二线路认证", icon: "network.badge.shield.half.filled")
                HStack(spacing: 12) {
                    GlassAction(title: "重新认证第二线路", icon: "arrow.triangle.2.circlepath", prominent: true) { model.performDual("restart") }
                    GlassAction(title: "启动", icon: "play.fill") { model.performDual("start") }
                    GlassAction(title: "停止", icon: "stop.fill") { model.performDual("stop") }
                    Spacer()
                }.disabled(!model.connected || model.busy || !installed)
                Divider().padding(.vertical, 16).opacity(0.5)
                HStack {
                    Text("认证失败后不会由维护任务反复拉起。原主线路单独控制。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看第二线路日志") { model.loadSecondLogs() }
                        .buttonStyle(.glass).disabled(!model.connected || model.busy || !installed)
                }
            }
            Surface {
                cardTitle("第二账号与密码", icon: "person.crop.circle")
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                    GridRow {
                        field("第二校园网账号", hint: "保存在路由器的独立配置中") { TextField("输入第二账号", text: model.editedSecond(\.secondAccount)) }
                        field("修改第二账号密码", hint: "留空保留现有密码") { SecureField("仅在修改密码时填写", text: model.editedSecond(\.secondPassword)) }
                    }
                }.disabled(!model.connected || model.busy || !installed)
                Divider().padding(.vertical, 18).opacity(0.5)
                HStack {
                    Text(model.revealedSecondPassword.isEmpty ? "••••••••••••" : model.revealedSecondPassword)
                        .font(.system(size: 16, design: .monospaced)).lineLimit(2)
                    Spacer()
                    Button(model.revealedSecondPassword.isEmpty ? "显示第二账号密码" : "隐藏密码") {
                        if model.revealedSecondPassword.isEmpty { model.revealCampusPassword(second: true) } else { model.hideCampusPassword() }
                    }.buttonStyle(.glass).disabled(!model.connected || model.busy || !installed)
                }
                HStack {
                    Text("显示后 30 秒自动隐藏。保存不会自动重新认证。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    GlassAction(title: "保存第二账号", icon: "checkmark", prominent: true) { model.saveSecondAccount() }
                        .disabled(!model.connected || model.busy || !installed || !model.secondConfigDirty)
                }.padding(.top, 18)
            }
            if !installed {
                Text("当前路由器尚未安装双线路组件。本次提供的组件针对这台 AX3000，App 不会自动改动其他路由器端口。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var scheduleCard: some View {
        Surface {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("定时重新认证", systemImage: "clock.arrow.2.circlepath").font(.system(size: 13, weight: .semibold))
                    Text("在路由器执行，关闭 App 后仍有效。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("定时重新认证", isOn: Binding(get: { model.scheduleEnabled }, set: { model.configureSchedule(enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch).disabled(!model.connected || model.busy)
            }
            HStack(spacing: 12) {
                Text("认证间隔").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("认证间隔", selection: Binding(get: { model.scheduleHours }, set: { model.changeScheduleHours($0) })) {
                    Text("每 24 小时").tag(24); Text("每 48 小时").tag(48)
                    Text("每 72 小时").tag(72); Text("每 7 天").tag(168)
                }.labelsHidden().frame(width: 150).disabled(!model.connected || model.busy)
                Spacer()
                Text(model.scheduleEnabled ? "已开启" : "已关闭").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.scheduleEnabled ? Color.green : Color.secondary)
            }.padding(.top, 16)
            infoRow("下一次认证", model.scheduleEnabled ? model.scheduleDate("TimerNext") : "—")
            if !model.snapshot["TimerResult"].isEmpty {
                infoRow("最近执行", model.scheduleDate("TimerLast"))
                Text(model.snapshot["TimerResult"]).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
            }
            Text("开启或修改间隔后重新计时，不会立即认证；断线时跳过本次，不补发连续认证。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 7)
        }
    }

    private var campusPasswordCard: some View {
        Surface {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Label("路由器保存的校园网密码", systemImage: "key.horizontal").font(.system(size: 13, weight: .semibold))
                    Text(model.revealedCampusPassword.isEmpty ? "••••••••••••" : model.revealedCampusPassword)
                        .font(.system(size: 15, design: .monospaced))
                }
                Spacer()
                GlassAction(title: model.revealedCampusPassword.isEmpty ? "显示密码" : "隐藏密码",
                            icon: model.revealedCampusPassword.isEmpty ? "eye" : "eye.slash") {
                    if model.revealedCampusPassword.isEmpty { model.revealCampusPassword() } else { model.hideCampusPassword() }
                }.disabled(!model.connected || model.busy)
            }
            Text("点击后通过 SSH 读取；30 秒后或离开当前页面时隐藏，不持久保存，不写入活动日志。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 10)
        }
    }

    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content().textFieldStyle(.roundedBorder).controlSize(.large).frame(maxWidth: .infinity)
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var logFilter = ""
    private var visibleLog: String {
        if logFilter.isEmpty { return model.logText }
        return model.logText.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(logFilter) }.joined(separator: "\n")
    }
    private var logs: some View {
        VStack(spacing: 18) {
            Surface(padding: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选日志内容", text: $logFilter).textFieldStyle(.plain)
                    Spacer()
                    Button("导出", systemImage: "square.and.arrow.up") { model.exportLogs() }.buttonStyle(.glass).disabled(model.logText.isEmpty)
                    Button("读取日志", systemImage: "arrow.clockwise") { model.loadLogs() }.buttonStyle(.glassProminent).tint(accent).disabled(model.busy || !model.connected)
                }
            }
            Surface(padding: 0) {
                HStack {
                    Circle().fill(Color.green.opacity(0.7)).frame(width: 6, height: 6)
                    Text("路由器认证日志").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("最多 180 行 / 文件").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(20)
                Divider().opacity(0.4)
                ScrollView([.horizontal, .vertical]) {
                    Text(visibleLog.isEmpty ? (model.logText.isEmpty ? "点击「读取日志」，查看路由器上的认证记录。" : "没有匹配的日志。") : visibleLog)
                        .font(.system(size: 12, design: .monospaced)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                }.frame(minHeight: 420, maxHeight: 520)
            }
            Text("常见密码字段会隐藏；日志仍可能包含 IP、MAC 或账号，请检查后再分享。")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if model.logText.isEmpty && model.connected && !model.busy { model.loadLogs() } }
    }

    private var settings: some View {
        VStack(spacing: 18) {
            Surface {
                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "link.circle.fill").font(.system(size: 36)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("连接你的路由器").font(.system(size: 20, weight: .semibold))
                        Text("连接路由器主 Wi-Fi 或 LAN 网线即可。校园网断开时，本地管理仍然可用。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                }.padding(.bottom, 22)
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 20) {
                    GridRow {
                        field("路由器地址", hint: "小米默认管理地址") { TextField("192.168.31.1", text: $model.connection.host) }
                        field("SSH 端口", hint: "默认 22") { TextField("22", text: $model.connection.port) }
                    }
                    GridRow {
                        field("SSH 用户名", hint: "路由器管理账号") { TextField("root", text: $model.connection.user) }
                        field("SSH 密码", hint: "与校园网账号密码不同") { SecureField("输入路由器密码", text: $model.sshPassword) }
                    }
                }.disabled(model.busy)
                Toggle("将 SSH 密码保存到这台 Mac 的钥匙串", isOn: $model.rememberPassword)
                    .font(.system(size: 12)).toggleStyle(.checkbox).padding(.top, 22).disabled(model.busy)
                Text("默认仅保存在本次 App 会话内。校园网密码不会持久保存在 Mac。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 5)
                Divider().padding(.vertical, 20).opacity(0.5)
                HStack {
                    Label("兼容小米原厂 Dropbear SSH", systemImage: "checkmark.shield")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    GlassAction(title: "连接并读取状态", icon: "link", prominent: true) { model.connect() }.disabled(model.busy || model.sshPassword.isEmpty)
                }
            }
            Surface {
                cardTitle("状态刷新", icon: "arrow.clockwise.circle")
                Toggle("每 30 秒刷新路由器状态", isOn: $model.autoRefresh).toggleStyle(.switch).font(.system(size: 12))
                Text("只在 App 打开且路由器已连接时刷新，不会自动重启认证。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 7)
            }
            Surface {
                cardTitle("无线国家／地区", icon: "globe.asia.australia")
                infoRow("2.4 GHz 当前运行", model.connected ? WirelessRegion.runtimeDisplay(model.snapshot["WifiRuntimeCountry0ID"]) : "待连接读取")
                infoRow("5 GHz 当前运行", model.connected ? WirelessRegion.runtimeDisplay(model.snapshot["WifiRuntimeCountry1ID"]) : "待连接读取")
                infoRow("已保存 · 2.4 / 5 GHz", model.connected ? WirelessRegion.display(code: model.snapshot["WifiCountry0"]) + " / " + WirelessRegion.display(code: model.snapshot["WifiCountry1"]) : "—")
                Divider().padding(.vertical, 16).opacity(0.5)
                HStack {
                    Picker("实际使用国家／地区", selection: Binding(get: { model.selectedWifiRegion }, set: { model.selectedWifiRegion = $0; model.wifiRegionDirty = true })) {
                        ForEach(WirelessRegion.options) { region in Text("\(region.name)（\(region.code)）").tag(region.code) }
                    }.frame(maxWidth: 350)
                    Spacer()
                    Button("保存区域") { model.saveWifiRegion() }.buttonStyle(.glass)
                        .disabled(!model.connected || model.busy || model.snapshot["WifiRegionSupported"] != "yes" || (!model.wifiRegionDirty && model.selectedWifiRegion == model.snapshot["WifiCountry0"] && model.selectedWifiRegion == model.snapshot["WifiCountry1"]))
                }.disabled(model.snapshot["WifiRegionJob"] == "queued" || model.snapshot["WifiRegionJob"] == "applying" || model.snapshot["WifiRegionJob"] == "restoring")
                HStack {
                    Text(model.wifiRegionJobDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("重启无线并应用") { regionApplyConfirmation = true }.buttonStyle(.glass)
                        .disabled(!model.connected || model.busy || model.wifiRegionDirty || model.snapshot["WifiRegionPending"] != "yes" || ["queued", "applying", "restoring"].contains(model.snapshot["WifiRegionJob"]))
                }.padding(.top, 12)
                Text("请选择路由器实际所在地区。保存同时设置两个频段；应用时由原厂驱动执行区域规则，保留雷达检测和功率限制。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
            }
            Surface {
                cardTitle("5 GHz 无线带宽", icon: "wifi")
                infoRow("当前运行带宽", model.snapshot["WifiRuntimeWidth"].isEmpty ? "—" : model.snapshot["WifiRuntimeWidth"] + " MHz")
                infoRow("配置带宽", model.snapshot["WifiConfiguredWidth"] == "0" ? "自动" : model.snapshot["WifiConfiguredWidth"].isEmpty ? "—" : model.snapshot["WifiConfiguredWidth"] + " MHz")
                infoRow("主信道 / 地区", model.connected ? model.snapshot["WifiChannel"] + " / " + model.snapshot["WifiCountry"] : "—")
                HStack {
                    Text("保留雷达检测。160 MHz 连接还取决于终端能力与无线环境。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.snapshot["WifiConfiguredWidth"] == "160" ? "已固定 160 MHz" : "固定为 160 MHz") { model.fixWifiWidth() }
                        .buttonStyle(.glass).disabled(model.busy || !model.connected || model.snapshot["WifiRuntimeWidth"] != "160" || model.snapshot["WifiConfiguredWidth"] == "160")
                }.padding(.top, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.busy ? "hourglass" : "info.circle").font(.system(size: 10)).foregroundStyle(accent)
            Text(model.busy ? model.busyTitle + "…" : model.lastNotice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if let updated = model.refreshedAt {
                Text("更新于 " + updated.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}
