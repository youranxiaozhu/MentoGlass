import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum Section: String, CaseIterable, Identifiable {
    case overview = "概览", authentication = "认证管理", dualwan = "双线路", logs = "运行日志", settings = "连接设置"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .authentication: return "network.badge.shield.half.filled"
        case .dualwan: return "arrow.triangle.branch"
        case .logs: return "text.alignleft"
        case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "路由器、认证与网络，一眼掌握。"
        case .authentication: return "管理校园网认证与自动重试。"
        case .dualwan: return "两个授权账号，为多个任务分担流量。"
        case .logs: return "查看路由器返回的真实认证记录。"
        case .settings: return "通过局域网安全连接你的路由器。"
        }
    }
}

struct Activity: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let detail: String
    let success: Bool
}

@MainActor final class RouterModel: ObservableObject {
    @Published var section: Section = .overview
    @Published var connection = RouterConnection()
    @Published var sshPassword = ""
    @Published var rememberPassword = false
    @Published var connected = false
    @Published var busy = false
    @Published var busyTitle = ""
    @Published var snapshot = RouterSnapshot("")
    @Published var online: Bool?
    @Published var dnsOK: Bool?
    @Published var networkCheckedAt: Date?
    @Published var refreshedAt: Date?
    @Published var activity: [Activity] = []
    @Published var logText = ""
    @Published var errorText: String?
    @Published var autoRefresh = false
    @Published var account = ""
    @Published var campusPassword = ""
    @Published var nic = "eth0"
    @Published var authMode = "1"
    @Published var dhcpMode = "2"
    @Published var echoInterval = "30"
    @Published var restartWait = "15"
    @Published var maxFail = "0"
    @Published var configurationLoaded = false
    @Published var configDirty = false
    @Published var scheduleEnabled = false
    @Published var scheduleHours = 24
    @Published var revealedCampusPassword = ""
    @Published var secondAccount = ""
    @Published var secondPassword = ""
    @Published var revealedSecondPassword = ""
    @Published var secondConfigDirty = false
    @Published var selectedWifiRegion = "CN"
    @Published var wifiRegionDirty = false
    private var revealGeneration = 0
    private var hidePasswordTask: Task<Void, Never>?
    @Published var lastNotice = "连接主 Wi-Fi，也能管理校园网认证。"

    init() {
        if let data = UserDefaults.standard.data(forKey: "connection"),
           let saved = try? JSONDecoder().decode(RouterConnection.self, from: data) { connection = saved }
        rememberPassword = UserDefaults.standard.bool(forKey: "rememberPassword")
        if rememberPassword { loadSavedLogin() }
    }
    private func loadSavedLogin() {
        let identity = connection.identity
        Task { @MainActor [weak self] in
            let saved = await Task.detached { SecretStore.load(identity) }.value
            guard let self, self.connection.identity == identity,
                  self.rememberPassword, self.sshPassword.isEmpty else { return }
            if let saved {
                self.sshPassword = saved
                if !self.busy { self.refresh() }
            } else {
                self.lastNotice = "请重新输入路由器 SSH 密码；已保存的钥匙串项目暂时不可读取。"
            }
        }
    }

    var wanIP: String { snapshot["wanIP"].isEmpty ? "尚未获取" : snapshot["wanIP"] }
    var runtime: String {
        guard let seconds = Double(snapshot["uptime"]) else { return "—" }
        let hours = Int(seconds) / 3600
        return hours > 23 ? "\(hours / 24) 天 \(hours % 24) 小时" : "\(hours) 小时 \(Int(seconds) % 3600 / 60) 分钟"
    }
    var configWarning: Bool { configurationLoaded && snapshot["DhcpScript"].trimmingCharacters(in: .whitespaces).hasSuffix("-i") }
    var anyCredentials: Bool { !sshPassword.isEmpty }

    func edited(_ path: ReferenceWritableKeyPath<RouterModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: path] }, set: { self[keyPath: path] = $0; self.configDirty = true })
    }

    func scrub(_ text: String) -> String {
        var output = text
        for secret in [sshPassword, campusPassword, revealedCampusPassword, secondPassword, revealedSecondPassword] where !secret.isEmpty {
            output = output.replacingOccurrences(of: secret, with: "••••")
        }
        output = output.replacingOccurrences(of: "(?im)^.*(?:password\\s*=|passwd\\s*=|encodepass\\s*=).*$", with: "[密码字段已隐藏]", options: .regularExpression)
        return output
    }
    func friendlyError(_ text: String) -> String {
        if text.contains("Permission denied") { return "SSH 登录失败。请检查用户名和密码；这里需要的是路由器密码，不是校园网密码。" }
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return "路由器身份与之前记录不一致。请核实设备或固件是否更换；App 已停止连接。" }
        if text.contains("No route to host") || text.contains("timed out") || text.contains("Connection refused") {
            return "无法连接路由器。请确认连接主 Wi-Fi，管理地址和 SSH 服务正确。"
        }
        return scrub(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func record(_ title: String, _ detail: String, success: Bool = true) {
        activity.insert(Activity(title: title, detail: scrub(detail), success: success), at: 0)
        if activity.count > 30 { activity.removeLast() }
    }
    func execute(_ title: String, command: String, input: Data? = nil,
                 privateOutput: Bool = false,
                 completion: @escaping (String) -> Void) {
        guard !busy else { return }
        do { try connection.validate() } catch { errorText = error.localizedDescription; return }
        guard anyCredentials else { section = .settings; errorText = "请输入路由器 SSH 密码后再连接。"; return }
        busy = true; busyTitle = title
        let c = connection, password = sshPassword
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SSHClient.run(connection: c, password: password, command: command, input: input, timeout: 25)
                }.value
                busy = false
                guard result.code == 0 else {
                    if result.code == 255 { connected = false; online = nil; dnsOK = nil }
                    let message = privateOutput ? "读取校园网密码失败，请检查路由器连接与配置。" : friendlyError(result.output)
                    errorText = message.isEmpty ? "操作失败（\(result.code)）。" : message
                    record(title, errorText ?? "操作失败", success: false)
                    return
                }
                connected = true
                completion(result.output)
                record(title, "操作完成 · \(connection.host)")
            } catch {
                busy = false; connected = false; online = nil; dnsOK = nil
                errorText = error.localizedDescription
                record(title, error.localizedDescription, success: false)
            }
        }
    }
    func connect() {
        configurationLoaded = false; configDirty = false; online = nil; dnsOK = nil
        execute("连接路由器", command: RouterCommands.status) { [self] output in
            self.apply(output)
            do {
                UserDefaults.standard.set(try JSONEncoder().encode(self.connection), forKey: "connection")
                UserDefaults.standard.set(self.rememberPassword, forKey: "rememberPassword")
                let password = self.sshPassword, identity = self.connection.identity, remember = self.rememberPassword
                Task { @MainActor [weak self] in
                    do {
                        try await Task.detached {
                            if remember { try SecretStore.save(password, account: identity) }
                            else { SecretStore.remove(identity) }
                        }.value
                    } catch { self?.errorText = error.localizedDescription }
                }
            } catch { self.errorText = error.localizedDescription }
        }
    }
    func connectionChanged() {
        hideCampusPassword()
        connected = false; configurationLoaded = false; configDirty = false
        snapshot = RouterSnapshot(""); online = nil; dnsOK = nil
        networkCheckedAt = nil; refreshedAt = nil
        sshPassword = ""
        if rememberPassword { loadSavedLogin() }
        lastNotice = "连接设置已更改，请重新连接路由器。"
        scheduleEnabled = false
        secondAccount = ""; secondPassword = ""; secondConfigDirty = false
        selectedWifiRegion = "CN"; wifiRegionDirty = false
    }
    func apply(_ output: String) {
        snapshot = RouterSnapshot(output); refreshedAt = Date()
        applySchedule(snapshot)
        updateRegionSelection()
        if !secondConfigDirty { secondAccount = snapshot["SecondUsername"] }
        if !configurationLoaded || !configDirty {
            account = snapshot["Username"]
            if !snapshot["Nic"].isEmpty { nic = snapshot["Nic"] }
            if !snapshot["StartMode"].isEmpty { authMode = snapshot["StartMode"] }
            if !snapshot["DhcpMode"].isEmpty { dhcpMode = snapshot["DhcpMode"] }
            if !snapshot["EchoInterval"].isEmpty { echoInterval = snapshot["EchoInterval"] }
            if !snapshot["RestartWait"].isEmpty { restartWait = snapshot["RestartWait"] }
            if !snapshot["MaxFail"].isEmpty { maxFail = snapshot["MaxFail"] }
            configurationLoaded = true
        }
        lastNotice = "路由器连接成功。外网状态需要单独检测。"
    }
    func refresh() { execute("刷新路由器状态", command: RouterCommands.status) { self.apply($0) } }
    func testNetwork() {
        execute("检测外网连通性", command: RouterCommands.networkTest) {
            let values = RouterSnapshot($0)
            self.online = values["online"] == "yes"; self.dnsOK = values["dns"] == "yes"
            self.networkCheckedAt = Date()
            self.lastNotice = self.online == true ? "外网检测通过，校园网当前可用。" : "检测地址未响应。可查看日志，再尝试重新认证。"
        }
    }
    func loadLogs() {
        execute("读取认证日志", command: RouterCommands.logs) { self.logText = self.scrub($0) }
    }
    func perform(_ action: String) {
        let title = ["restart": "重新认证", "start": "启动认证", "stop": "停止认证与守护", "enable": "开启认证守护", "disable": "关闭认证守护"][action] ?? "认证操作"
        execute(title, command: RouterCommands.action(action)) {
            let result = RouterSnapshot($0)
            self.snapshot.values["running"] = result["running"]
            self.snapshot.values["enabled"] = result["enabled"]
            if !result["TimerEnabled"].isEmpty { self.applySchedule(result) }
            self.applyDual($0)
            self.online = nil; self.dnsOK = nil; self.networkCheckedAt = nil
            self.lastNotice = "\(title)操作已执行。请检测外网，确认网络是否恢复。"
            self.refreshedAt = Date()
        }
    }
    func saveConfig() {
        guard configurationLoaded else { errorText = "请先连接路由器并读取当前配置。"; return }
        var values = ["Username": account, "Nic": nic, "StartMode": authMode, "DhcpMode": dhcpMode,
                      "EchoInterval": echoInterval, "RestartWait": restartWait, "MaxFail": maxFail]
        do {
            if !campusPassword.isEmpty {
                if snapshot["PasswordFormat"] == "EncodePass" { values["EncodePass"] = try CampusSecret.encode(campusPassword) }
                else { values["Password"] = campusPassword }
            }
            let (command, input) = try RouterCommands.updateConfig(values: values)
            execute("保存认证配置", command: command, input: input) { _ in
                self.hideCampusPassword()
                self.campusPassword = ""; self.configDirty = false; self.configurationLoaded = false
                self.lastNotice = "配置已保存，原配置已在路由器备份。点击重新认证后生效。"
                self.refresh()
            }
        } catch { errorText = error.localizedDescription }
    }
    func applySchedule(_ values: RouterSnapshot) {
        for key in ["TimerEnabled", "TimerHours", "TimerNext", "TimerLast", "TimerResult"] {
            snapshot.values[key] = values[key]
        }
        scheduleEnabled = values["TimerEnabled"] == "yes"
        if let hours = Int(values["TimerHours"]), (24...168).contains(hours) { scheduleHours = hours }
    }
    func scheduleDate(_ key: String) -> String {
        guard let seconds = Double(snapshot[key]), seconds > 1700000000 else { return "—" }
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }
    func configureSchedule(enabled: Bool, hours: Int? = nil) {
        guard !busy else { return }
        if enabled && !snapshot.enabled { errorText = "请先开启认证守护，再开启定时重新认证。"; return }
        do {
            let requestedHours = hours ?? scheduleHours
            let (command, input) = try ExtensionCommands.schedule(enabled: enabled, hours: requestedHours)
            execute(enabled ? "开启定时认证" : "关闭定时认证", command: command, input: input) {
                self.applySchedule(RouterSnapshot($0))
                self.lastNotice = enabled ? "定时认证已开启，\(requestedHours) 小时后首次执行。" : "定时认证已关闭。"
            }
        } catch { errorText = error.localizedDescription }
    }
    func changeScheduleHours(_ hours: Int) {
        if scheduleEnabled { configureSchedule(enabled: true, hours: hours) }
        else { scheduleHours = hours }
    }
    func hideCampusPassword() {
        if !revealedCampusPassword.isEmpty || !revealedSecondPassword.isEmpty { lastNotice = "校园网密码已隐藏。" }
        revealGeneration += 1
        hidePasswordTask?.cancel(); hidePasswordTask = nil
        revealedCampusPassword = ""
        revealedSecondPassword = ""
    }
    func revealCampusPassword(second: Bool = false) {
        hideCampusPassword()
        let generation = revealGeneration
        let expectedSection: Section = second ? .dualwan : .authentication
        let command = second ? DualWANCommands.readPassword : ExtensionCommands.readPassword
        execute(second ? "查看第二账号密码" : "查看校园网密码", command: command, privateOutput: true) { [self] output in
            guard self.revealGeneration == generation, self.section == expectedSection else {
                self.lastNotice = "密码显示已取消，请在认证管理页面再次点击显示密码。"
                return
            }
            do {
                let secret = try CampusSecret.decode(output)
                if second { self.revealedSecondPassword = secret } else { self.revealedCampusPassword = secret }
                self.lastNotice = "校园网密码已显示，30 秒后自动隐藏。"
                self.hidePasswordTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.hideCampusPassword()
                }
            } catch { self.errorText = error.localizedDescription }
        }
    }
    func editedSecond(_ path: ReferenceWritableKeyPath<RouterModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: path] }, set: { self[keyPath: path] = $0; self.secondConfigDirty = true })
    }
    func applyDual(_ output: String) {
        let result = RouterSnapshot(output)
        for (key, value) in result.values where key.hasPrefix("Second") || key.hasPrefix("Balance") || key.hasPrefix("Hardware") || key == "DualInstalled" {
            snapshot.values[key] = value
        }
        if !secondConfigDirty { secondAccount = snapshot["SecondUsername"] }
        refreshedAt = Date()
    }
    func performDual(_ action: String) {
        do {
            let command = try DualWANCommands.action(action)
            let title = ["start": "启动第二线路", "restart": "重新认证第二线路", "stop": "停止第二线路", "balance-on": "开启双线路分流", "balance-off": "关闭双线路分流", "hardware-on": "开启双线路硬件加速", "hardware-off": "关闭双线路硬件加速"][action] ?? "第二线路操作"
            execute(title, command: command) { output in
                self.applyDual(output)
                self.lastNotice = action == "start" || action == "restart" ? "第二线路已启动，请刷新状态确认认证结果。" : "\(title)操作已执行。"
            }
        } catch { errorText = error.localizedDescription }
    }
    func saveSecondAccount() {
        do {
            let (command, payload) = try DualWANCommands.updateAccount(account: secondAccount, password: secondPassword)
            execute("保存第二账号配置", command: command, input: payload) { output in
                self.secondPassword = ""; self.secondConfigDirty = false
                self.hideCampusPassword(); self.applyDual(output)
                self.lastNotice = "第二账号配置已保存，重新认证后生效。"
            }
        } catch { errorText = error.localizedDescription }
    }
    func loadSecondLogs() {
        execute("读取第二线路日志", command: DualWANCommands.logs) {
            self.logText = self.scrub($0); self.section = .logs
        }
    }
    func fixWifiWidth() {
        execute("固定 5 GHz 带宽", command: ExtensionCommands.fix160) { output in
            let result = RouterSnapshot(output)
            for (key, value) in result.values where key.hasPrefix("Wifi") { self.snapshot.values[key] = value }
            self.lastNotice = "5 GHz 固定为 160 MHz，雷达保护保持开启。"
        }
    }
    var wifiRegionJobDescription: String {
        switch snapshot["WifiRegionJob"] {
        case "queued": return "等待重启无线；重新连接后请刷新。"
        case "applying": return "正在应用区域设置。"
        case "restoring": return "应用未成功，正在恢复原设置。"
        case "applied": return "无线驱动已加载新区域；DFS 信道可能仍在检测。"
        case "rolled-back": return "应用未成功，已恢复原无线配置，请检查当前运行区域。"
        case "rollback-failed": return "恢复无线未完成，请用网线连接路由器检查。"
        case "interrupted": return "上次应用任务中断，请重新读取并检查区域。"
        case "config-changed", "failed-config-changed": return "无线配置被其他操作修改，请重新读取后检查。"
        default: return snapshot["WifiRegionPending"] == "yes" ? "已保存，尚未重启无线应用。" : "区域以无线驱动的实际读数为准。"
        }
    }
    func updateRegionSelection() {
        let code = snapshot["WifiCountry1"]
        if !wifiRegionDirty && code == snapshot["WifiCountry0"] && WirelessRegion.options.contains(where: { $0.code == code }) {
            selectedWifiRegion = code
        }
    }
    private func applyWifi(_ output: String) {
        let result = RouterSnapshot(output)
        for (key, value) in result.values where key.hasPrefix("Wifi") { snapshot.values[key] = value }
        updateRegionSelection()
        refreshedAt = Date()
    }
    func saveWifiRegion() {
        do {
            let (command, payload) = try ExtensionCommands.saveRegion(selectedWifiRegion)
            execute("保存无线区域", command: command, input: payload) { output in
                self.wifiRegionDirty = false; self.applyWifi(output)
                self.lastNotice = self.snapshot["WifiRegionPending"] == "yes" ? "区域已保存；点击应用后重启无线生效。" : "当前无线区域已与保存的设置一致。"
            }
        } catch { errorText = error.localizedDescription }
    }
    func applyWifiRegion() {
        execute("应用无线区域", command: ExtensionCommands.applyRegion) { output in
            self.applyWifi(output)
            self.connected = false; self.online = nil; self.dnsOK = nil
            self.lastNotice = "无线应用任务已排队。重新连接路由器 Wi-Fi 后，请刷新状态确认结果。"
        }
    }
    func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MentoGlass-日志.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try scrub(logText).write(to: url, atomically: true, encoding: .utf8) }
            catch { errorText = error.localizedDescription }
        }
    }
}
