import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.windows.first?.center()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

struct MentoGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = RouterModel()
    var body: some Scene {
        Window("MentoGlass · 校园网控制中心", id: "main") {
            RootView().environmentObject(model).tint(Color(red: 0.12, green: 0.45, blue: 0.95))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("连接设置…") { model.section = .settings }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("路由器") {
                Button("刷新状态") { model.refresh() }.keyboardShortcut("r", modifiers: .command).disabled(model.busy)
                Button("检测外网") { model.testNetwork() }.disabled(model.busy || !model.connected)
                Button("查看日志") { model.section = .logs }.keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}

@main enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest(); print("PASS: validation, SSH quoting, snapshot parsing, protected config payload, password decoding, timer resource."); exit(0) }
            catch { fputs("Self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--live-check") {
            do {
                guard let password = ProcessInfo.processInfo.environment["MENTOGLASS_TEST_PASSWORD"] else {
                    throw RouterError.message("Missing test credential.")
                }
                let connection = RouterConnection()
                let result = try SSHClient.run(connection: connection, password: password, command: RouterCommands.status)
                guard result.code == 0 else { throw RouterError.message("Live SSH status failed (\(result.code)).") }
                let status = RouterSnapshot(result.output)
                guard !status["host"].isEmpty, ["yes", "no"].contains(status["running"]) else { throw RouterError.message("Unexpected router status.") }
                print("PASS: native SSH connected; status read and parsed; authentication process \(status.running ? "running" : "stopped").")
                let network = try SSHClient.run(connection: connection, password: password, command: RouterCommands.networkTest)
                guard network.code == 0 else { throw RouterError.message("Network check failed.") }
                let tested = RouterSnapshot(network.output)
                print("PASS: network test parsed; online=\(tested["online"]), dns=\(tested["dns"]).")
                let logs = try SSHClient.run(connection: connection, password: password, command: RouterCommands.logs)
                guard logs.code == 0 else { throw RouterError.message("Log read failed.") }
                print("PASS: router logs read; contents intentionally omitted from test output.")
                exit(0)
            } catch { fputs("Live check failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--dualwan-check") {
            do {
                guard let password = ProcessInfo.processInfo.environment["MENTOGLASS_TEST_PASSWORD"] else { throw RouterError.message("Missing router login.") }
                func run(_ command: String) throws -> String {
                    let result = try SSHClient.run(connection: RouterConnection(), password: password, command: command)
                    guard result.code == 0 else { throw RouterError.message("Dual WAN read failed (\(result.code)); private output omitted.") }
                    return result.output
                }
                let before = try run("pidof mentohust; pidof mentohus2; md5sum /data/mentohust/mentohust.conf")
                let status = RouterSnapshot(try run(RouterCommands.status))
                guard status["DualInstalled"] == "yes", status["SecondReady"] == "yes", status["BalanceActive"] == "yes",
                      status["SecondIP"] != status["wanIP"] else { throw RouterError.message("Dual WAN was not ready.") }
                let secondPassword = try CampusSecret.decode(run(DualWANCommands.readPassword))
                guard !secondPassword.isEmpty else { throw RouterError.message("Saved second-account password is empty.") }
                let after = try run("pidof mentohust; pidof mentohus2; md5sum /data/mentohust/mentohust.conf")
                guard before == after else { throw RouterError.message("Read-only check changed router state.") }
                print("PASS: native SSH parsed two ready lines and active balancing; password decoded privately; both processes and primary config unchanged.")
                exit(0)
            } catch { fputs("Dual WAN check failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--extensions-check") || CommandLine.arguments.contains("--configure-extensions") {
            do {
                guard let password = ProcessInfo.processInfo.environment["MENTOGLASS_TEST_PASSWORD"] else { throw RouterError.message("Missing test credential.") }
                let connection = RouterConnection()
                func run(_ command: String, input: Data? = nil) throws -> String {
                    let result = try SSHClient.run(connection: connection, password: password, command: command, input: input)
                    guard result.code == 0 else { throw RouterError.message("Router operation failed (\(result.code)); output omitted.") }
                    return result.output
                }
                let before = RouterSnapshot(try run(RouterCommands.status))
                guard Double(before["uptime"]) != nil else { throw RouterError.message("Router uptime did not parse.") }
                let pidBefore = try run("pidof mentohust").trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = try CampusSecret.decode(run(ExtensionCommands.readPassword))
                guard !secret.isEmpty else { throw RouterError.message("Empty secret.") }
                print("PASS: saved campus password decoded; contents omitted.")
                if CommandLine.arguments.contains("--configure-extensions") {
                    guard before["TimerEnabled"] != "yes" else { throw RouterError.message("Existing enabled schedule preserved; skipped installation.") }
                    let (command, input) = try ExtensionCommands.schedule(enabled: true, hours: 24, installInactive: true)
                    let installed = RouterSnapshot(try run(command, input: input))
                    guard installed["TimerEnabled"] == "no" else { throw RouterError.message("Schedule must be off.") }
                    print("PASS: router scheduler installed with switch OFF; no reauthentication triggered.")
                    let wifi = RouterSnapshot(try run(ExtensionCommands.fix160))
                    guard wifi["WifiConfiguredWidth"] == "160", wifi["WifiRuntimeWidth"] == "160", wifi["WifiCountry"] == before["WifiCountry"], wifi["WifiChannel"] == before["WifiChannel"] else { throw RouterError.message("Unexpected Wi-Fi settings.") }
                    print("PASS: saved 160 MHz width; runtime=160; country and channel unchanged; no radio reload.")
                }
                let pidAfter = try run("pidof mentohust").trimmingCharacters(in: .whitespacesAndNewlines)
                guard pidBefore == pidAfter else { throw RouterError.message("Authentication process changed during check.") }
                print("PASS: authentication process unchanged; no campus probes or reauthentication issued.")
                exit(0)
            } catch { fputs("Extension check failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        MentoGlassApp.main()
    }

    static func selfTest() throws {
        func check(_ condition: Bool) throws {
            if !condition { throw RouterError.message("Assertion failed.") }
        }
        try RouterConnection().validate()
        let (regionCommand, regionPayload) = try ExtensionCommands.saveRegion("CN")
        try check(!regionPayload.isEmpty && regionCommand.contains(" save CN"))
        try check(!regionCommand.contains("reload_legacy"))
        for invalid in ["00", "US;id", "cn", "US\n", "ZZ"] {
            do { _ = try ExtensionCommands.saveRegion(invalid); throw RouterError.message("Invalid region accepted.") }
            catch RouterError.message(let text) where text.hasPrefix("请选择列表中的") { }
        }
        try check(WirelessRegion.runtimeDisplay("156").contains("CN"))
        let (secondCommand, secondPayload) = try DualWANCommands.updateAccount(account: "test;$(id)", password: "test-only-secret!")
        try check(!secondCommand.contains("test;$(id)"))
        try check(!secondCommand.contains("test-only-secret!"))
        let secondText = String(decoding: secondPayload, as: UTF8.self)
        try check(!secondText.contains("test-only-secret!"))
        try check(try CampusSecret.decode(secondText) == "test-only-secret!")
        try check(secondCommand.contains("/data/mentoglass-dualwan/mentohus2.conf"))
        try check(!secondCommand.contains("ln -sf"))
        for action in ["start", "stop", "restart", "balance-on", "balance-off"] { _ = try DualWANCommands.action(action) }
        do { _ = try DualWANCommands.action("start;id"); throw RouterError.message("Unsafe dual action accepted.") }
        catch RouterError.message(let text) where text == "不支持的第二线路操作。" { }
        do { _ = try DualWANCommands.updateAccount(account: "bad\nNic=eth0", password: ""); throw RouterError.message("Multiline second account accepted.") }
        catch RouterError.message(let text) where text.hasPrefix("请检查第二账号") { }
        for host in ["-oProxyCommand=id", "localhost;id", "", "abc\nxyz"] {
            var c = RouterConnection(); c.host = host
            do { try c.validate(); throw RouterError.message("Invalid host accepted.") }
            catch RouterError.message(let text) where text.hasPrefix("请填写") { }
        }
        try check(SSHClient.quote("a'b;$(id)") == "'a'\"'\"'b;$(id)'")
        let s = RouterSnapshot("enabled=yes\nrunning=no\nwanIP=10.0.0.2\nDhcpScript=udhcpc -i eth0\nWarning: ignored\n")
        try check(s.enabled && !s.running && s["wanIP"] == "10.0.0.2")
        try check(s["DhcpScript"] == "udhcpc -i eth0")
        var values = ["Username": "test", "Password": "a'b;$(id)=z", "Nic": "eth0", "StartMode": "1", "DhcpMode": "2", "EchoInterval": "30", "RestartWait": "15", "MaxFail": "0"]
        let (command, payload) = try RouterCommands.updateConfig(values: values)
        try check(!command.contains(values["Password"]!) && String(data: payload, encoding: .utf8)!.contains("Password=a'b;$(id)=z\n"))
        try check(command.contains("mentoglass-backup"))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mentoglass-config-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = temp.appendingPathComponent("mentohust.conf")
        let original = "; keep comment\n[MentoHUST]\nUsername=old\nPassword=old\nNic=eth0\nStartMode=1\nDhcpMode=2\nEchoInterval=30\nRestartWait=15\nMaxFail=4\nDhcpScript=udhcpc -i\nUnknown=keep\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let localCommand = command.replacingOccurrences(of: RouterCommands.config, with: config.path)
            .replacingOccurrences(of: "/data/mentohust/.mentoglass-conf", with: temp.appendingPathComponent(".new").path)
            .replacingOccurrences(of: "/etc/mentohust.conf", with: temp.appendingPathComponent("active.conf").path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", localCommand]
        let stdin = Pipe(); process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); try stdin.fileHandleForWriting.write(contentsOf: payload)
        try stdin.fileHandleForWriting.close(); process.waitUntilExit()
        try check(process.terminationStatus == 0)
        let updated = try String(contentsOf: config, encoding: .utf8)
        try check(updated.contains("; keep comment") && updated.contains("Unknown=keep") && updated.contains("DhcpScript=udhcpc -i"))
        try check(RouterSnapshot(updated)["Password"] == values["Password"]!)
        try check(try String(contentsOf: URL(fileURLWithPath: config.path + ".mentoglass-backup"), encoding: .utf8) == original)
        values["Password"] = "secret\nNic=evil"
        do { _ = try RouterCommands.updateConfig(values: values); throw RouterError.message("Multiline config accepted.") }
        catch RouterError.message(let text) where text.hasPrefix("配置中") { }
        for password in ["a'b;$(id)=z", "中文-password", " leading-space", "x"] {
            let encoded = try CampusSecret.encode(password)
            try check(try CampusSecret.decode("EncodePass=\(encoded)\n") == password)
            try check(try CampusSecret.decode("Password= \(encoded)\n") == password)
        }
        try check(try CampusSecret.decode("Password=ordinary=secret\n") == "ordinary=secret")
        do { _ = try CampusSecret.decode("EncodePass=not base64\n"); throw RouterError.message("Bad encoding accepted.") }
        catch RouterError.message(let text) where text.hasPrefix("路由器中的") { }
        let (install, script) = try ExtensionCommands.schedule(enabled: true, hours: 24, installInactive: true)
        try check(script != nil && install.hasSuffix(" disable") && !install.contains(" enable 24"))
        let (off, _) = try ExtensionCommands.schedule(enabled: false, hours: 24)
        try check(off.contains(" disable") && !off.contains(" stop"))
        do { _ = try ExtensionCommands.schedule(enabled: true, hours: 1); throw RouterError.message("Short interval accepted.") }
        catch RouterError.message(let text) where text.hasPrefix("定时认证间隔") { }
    }
}
