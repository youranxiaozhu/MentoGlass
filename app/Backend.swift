import Foundation
import Security
import LocalAuthentication

struct RouterConnection: Codable {
    var host = "192.168.31.1"
    var port = "22"
    var user = "root"
    func validate() throws {
        guard !host.isEmpty, host.count < 254,
              host.range(of: "^[A-Za-z0-9][A-Za-z0-9.:-]*$", options: .regularExpression) != nil,
              let portNumber = Int(port), (1...65535).contains(portNumber),
              user.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            throw RouterError.message("请填写有效的路由器地址、端口和 SSH 用户名。")
        }
    }
    var identity: String { "\(user)@\(host):\(port)" }
}

enum RouterError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

struct SSHResult { let code: Int32; let output: String }

enum SSHClient {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func run(connection: RouterConnection, password: String, command: String,
                    input: Data? = nil, timeout: TimeInterval = 20) throws -> SSHResult {
        try connection.validate()
        guard !password.isEmpty else { throw RouterError.message("请输入路由器的 SSH 密码。") }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("mentoglass-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let secret = temp.appendingPathComponent("secret")
        let askpass = temp.appendingPathComponent("askpass")
        try Data(password.utf8).write(to: secret, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        try Data("#!/bin/sh\nexec /bin/cat \"$MENTOGLASS_SECRET_FILE\"\n".utf8).write(to: askpass)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MentoGlass")
        try fm.createDirectory(at: support, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let stdoutURL = temp.appendingPathComponent("stdout")
        let stderrURL = temp.appendingPathComponent("stderr")
        fm.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T", "-p", connection.port,
            "-o", "HostKeyAlgorithms=+ssh-rsa",
            "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(support.appendingPathComponent("known_hosts").path)",
            "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "\(connection.user)@\(connection.host)", command
        ]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpass.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = ":0"
        env["MENTOGLASS_SECRET_FILE"] = secret.path
        process.environment = env
        process.standardOutput = stdout; process.standardError = stderr
        let stdin = Pipe(); process.standardInput = stdin
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if let input = input { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw RouterError.message("连接超时。请确认连接的是路由器主 Wi-Fi，或路由器 LAN 网线。")
        }
        try stdout.synchronize(); try stderr.synchronize()
        let output = (String(data: try Data(contentsOf: stdoutURL), encoding: .utf8) ?? "")
            + (String(data: try Data(contentsOf: stderrURL), encoding: .utf8) ?? "")
        return SSHResult(code: process.terminationStatus, output: output)
    }
}

enum SecretStore {
    static let service = "local.mentoglass.router"
    static func load(_ account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account,
                                   kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne,
                                   kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let update = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(password.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw RouterError.message("无法保存到钥匙串（\(result)）。") }
        } else if status != errSecSuccess {
            throw RouterError.message("无法更新钥匙串（\(status)）。")
        }
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

struct RouterSnapshot {
    var values: [String: String] = [:]
    init(_ output: String) {
        for line in output.components(separatedBy: .newlines) {
            guard let index = line.firstIndex(of: "=") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { continue }
            values[key] = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        }
    }
    subscript(_ key: String) -> String { values[key] ?? "" }
    var running: Bool { self["running"] == "yes" }
    var enabled: Bool { self["enabled"] == "yes" }
}

enum RouterCommands {
    static let boot = "/etc/crontabs/patches/mentohust_boot.sh"
    static let config = "/data/mentohust/mentohust.conf"
    static let status = """
    test -x /data/mentohust/mentohust && test -f \(boot) || { echo 'MentoHUST 或维护脚本未找到。'; exit 2; }
    \(boot) status
    printf 'host='; cat /proc/sys/kernel/hostname
    printf 'uptime='; cut -d' ' -f1 /proc/uptime
    printf 'wanIP='; ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\\([^ ]*\\).*/\\1/p'
    printf 'gateway='; route -n | awk '$1=="0.0.0.0" {print $2; exit}'
    printf 'carrier='; cat /sys/class/net/eth0/carrier 2>/dev/null
    printf 'version='; cat /etc/miwifi_version 2>/dev/null | sed -n 's/^option ROM \\"\\([^\\"]*\\)\\"/\\1/p' | head -n 1
    sed -n '/^Nic=/p;/^Username=/p;/^DhcpMode=/p;/^StartMode=/p;/^EchoInterval=/p;/^RestartWait=/p;/^MaxFail=/p;/^PingHost=/p;/^DhcpScript=/p' \(config)
    awk -F= '$1=="EncodePass"{encoded=1} END {print "PasswordFormat=" (encoded ? "EncodePass" : "Password")}' \(config)
    \(ExtensionCommands.readStatus)
    \(DualWANCommands.status)
    """
    static let logs = """
    for f in /tmp/mentohust.log /tmp/mentohust-start.log; do
      printf '\\n──── %s ────\\n' "$f"
      if [ -f "$f" ]; then tail -n 180 "$f" | sed '/[Pp]assword/d;/[Pp]asswd/d;/[Ee]ncode[Pp]ass/d;/^Username=/d;/用户名/d;/密码/d'; else echo '暂无日志'; fi
    done
    """
    static let networkTest = """
    if ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then echo 'online=yes'; echo 'target=223.5.5.5';
    elif ping -c 2 -W 2 119.29.29.29 >/dev/null 2>&1; then echo 'online=yes'; echo 'target=119.29.29.29';
    else echo 'online=no'; echo 'target=两个检测地址均无响应'; fi
    if nslookup www.baidu.com >/dev/null 2>&1; then echo 'dns=yes'; else echo 'dns=no'; fi
    """
    static func action(_ action: String) -> String {
        let command: String
        switch action {
        case "restart": command = "\(boot) stop; sleep 1; if pidof mentohust >/dev/null; then killall mentohust 2>/dev/null; sleep 1; fi; \(boot) start; sleep 2; \(boot) status"
        case "start": command = "\(boot) enable; \(boot) start; sleep 2; \(boot) status"
        case "stop": command = "if [ -x \(ExtensionCommands.scheduler) ]; then \(ExtensionCommands.scheduler) disable >/dev/null; fi; \(boot) disable; sleep 1; \(boot) status; \(ExtensionCommands.readStatus)"
        case "enable": command = "\(boot) enable; \(boot) status"
        case "disable": command = "rm -f /data/mentohust/enabled; \(boot) status"
        default: return "exit 2"
        }
        return command + "\nif [ -x \(DualWANCommands.script) ]; then \(DualWANCommands.script) maintain; fi\n" + DualWANCommands.status
    }
    static func updateConfig(values: [String: String]) throws -> (String, Data) {
        let allowed = Set(["Username", "Password", "EncodePass", "Nic", "StartMode", "DhcpMode", "EchoInterval", "RestartWait", "MaxFail"])
        for (key, value) in values {
            guard allowed.contains(key), !value.contains("\n"), !value.contains("\r"), !value.contains("\0"), value.count < 256 else {
                throw RouterError.message("配置中包含不支持的字符或字段。")
            }
        }
        guard values["Nic"]?.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil,
              let echo = Int(values["EchoInterval"] ?? ""), (1...999).contains(echo),
              let restart = Int(values["RestartWait"] ?? ""), (1...99).contains(restart),
              let maxFail = Int(values["MaxFail"] ?? ""), maxFail >= 0,
              ["0", "1", "2"].contains(values["StartMode"] ?? ""),
              ["0", "1", "2", "3"].contains(values["DhcpMode"] ?? "") else {
            throw RouterError.message("请检查网卡名称、认证模式和时间参数。")
        }
        let payload = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
        // Password travels via SSH stdin, never via command arguments. Keep a private rollback file.
        let command = """
        umask 077
        CONF=\(config)
        test -f "$CONF" || exit 2
        PATCH=$(mktemp /tmp/mentoglass-patch.XXXXXX) || exit 3
        NEW=$(mktemp /data/mentohust/.mentoglass-conf.XXXXXX) || { rm -f "$PATCH"; exit 3; }
        trap 'rm -f "$PATCH" "$NEW"' EXIT HUP INT TERM
        cat > "$PATCH" || exit 3
        cp -p "$CONF" "$CONF.mentoglass-backup" || exit 3
        chmod 600 "$CONF.mentoglass-backup"
        awk 'FILENAME==ARGV[1] {i=index($0,"="); k=substr($0,1,i-1); p[k]=substr($0,i+1); next} {i=index($0,"="); k=substr($0,1,i-1); if(k in p){print k "=" p[k]; done[k]=1}else{print}} END{for(k in p)if(!(k in done))print k "=" p[k]}' "$PATCH" "$CONF" > "$NEW" || exit 3
        chmod 600 "$NEW"
        mv "$NEW" "$CONF" || exit 3
        ln -sf "$CONF" /etc/mentohust.conf
        echo '配置已保存。点击重新认证后生效。'
        """
        return (command, Data(payload.utf8))
    }
}
