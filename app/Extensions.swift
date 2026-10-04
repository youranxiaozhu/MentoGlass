import Foundation

struct WirelessRegion: Identifiable {
    let code: String
    let name: String
    let driverID: String
    var id: String { code }
    static let options: [WirelessRegion] = [
        .init(code: "CN", name: "中国大陆", driverID: "156"), .init(code: "HK", name: "中国香港", driverID: "344"),
        .init(code: "TW", name: "中国台湾", driverID: "158"), .init(code: "US", name: "美国", driverID: "840"),
        .init(code: "CA", name: "加拿大", driverID: "124"), .init(code: "JP", name: "日本", driverID: "392"),
        .init(code: "KR", name: "韩国", driverID: "410"), .init(code: "SG", name: "新加坡", driverID: "702"),
        .init(code: "AU", name: "澳大利亚", driverID: "36"), .init(code: "NZ", name: "新西兰", driverID: "554"),
        .init(code: "GB", name: "英国", driverID: "826"), .init(code: "DE", name: "德国", driverID: "276"),
        .init(code: "FR", name: "法国", driverID: "250"), .init(code: "RU", name: "俄罗斯", driverID: "643"),
        .init(code: "IN", name: "印度", driverID: "356"), .init(code: "TH", name: "泰国", driverID: "764"),
        .init(code: "MY", name: "马来西亚", driverID: "458"), .init(code: "ID", name: "印度尼西亚", driverID: "360"),
        .init(code: "VN", name: "越南", driverID: "704"), .init(code: "BR", name: "巴西", driverID: "76"),
        .init(code: "ZA", name: "南非", driverID: "710"), .init(code: "ES", name: "西班牙", driverID: "724"),
        .init(code: "IT", name: "意大利", driverID: "380"), .init(code: "NL", name: "荷兰", driverID: "528")
    ]
    static func display(code: String) -> String {
        options.first(where: { $0.code == code }).map { "\($0.name)（\($0.code)）" } ?? (code.isEmpty ? "尚未读取" : code)
    }
    static func runtimeDisplay(_ id: String) -> String {
        options.first(where: { $0.driverID == id }).map { display(code: $0.code) } ?? (id.isEmpty || id == "unknown" ? "无法读取" : "驱动区域 ID：\(id)")
    }
}

enum CampusSecret {
    private static let mask = Array("~!:?$*<(qw2e5o7i8x12c6m67s98w43d2l45we82q3iuu1z4xle23rt4oxclle34e54u6r8m".utf8)
    static func decode(_ output: String) throws -> String {
        let lines = output.components(separatedBy: .newlines)
        var plain: String?, encoded: String?
        for line in lines {
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: split)...]).replacingOccurrences(of: "\r", with: "")
            if key == "EncodePass" { encoded = value.trimmingCharacters(in: .whitespaces) }
            if key == "Password" {
                if value.hasPrefix(" ") { encoded = String(value.dropFirst()) } else { plain = value }
            }
        }
        if let value = encoded {
            guard let data = Data(base64Encoded: value), !data.isEmpty, data.count <= mask.count else {
                throw RouterError.message("路由器中的密码编码无法解析，未显示密码。")
            }
            let bytes = Array(data).enumerated().map { $0.element ^ mask[$0.offset] }
            guard let decoded = String(bytes: bytes, encoding: .utf8), !decoded.contains("\0"), !decoded.isEmpty else {
                throw RouterError.message("路由器中的密码格式不受支持，未显示密码。")
            }
            return decoded
        }
        guard let value = plain, !value.isEmpty else { throw RouterError.message("路由器配置中未找到校园网密码。") }
        return value
    }
    static func encode(_ password: String) throws -> String {
        let bytes = Array(password.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { throw RouterError.message("校园网密码需为 1–64 字节。") }
        return Data(bytes.enumerated().map { $0.element ^ mask[$0.offset] }).base64EncodedString()
    }
}

enum ExtensionCommands {
    static let scheduler = "/data/mentohust/mentoglass_schedule.sh"
    static let regionScript = "/data/mentoglass-wireless/region.sh"
    static let readPassword = """
    test -f /data/mentohust/mentohust.conf || exit 2
    awk 'index($0,"="){i=index($0,"="); k=substr($0,1,i-1); gsub(/^[ \\t]+|[ \\t]+$/,"",k); if(k=="Password" || k=="EncodePass") print k "=" substr($0,i+1)}' /data/mentohust/mentohust.conf
    """
    static let readStatus = """
    if [ -x \(scheduler) ]; then \(scheduler) status; else echo 'TimerEnabled=no'; echo 'TimerHours=24'; fi
    printf 'WifiConfiguredWidth='; uci -q get wireless.wifi1.bw || echo 'unknown'
    printf 'WifiHTMode='; uci -q get wireless.wifi1.htmode || echo 'unknown'
    printf 'WifiChannel='; uci -q get wireless.wifi1.channel || echo 'unknown'
    printf 'WifiCountry='; uci -q get wireless.wifi1.country || echo 'unknown'
    printf 'WifiMode='; iwpriv wl0 get_mode 2>/dev/null | sed 's/.*get_mode://'
    printf 'WifiRuntimeWidth='; iw dev wl0 info 2>/dev/null | sed -n 's/.*width: \\([0-9]*\\) MHz.*/\\1/p'
    if [ -x \(regionScript) ]; then \(regionScript) status; else echo 'WifiRegionInstalled=no'; fi
    """

    static func schedule(enabled: Bool, hours: Int, installInactive: Bool = false) throws -> (String, Data?) {
        guard (24...168).contains(hours) else { throw RouterError.message("定时认证间隔需为 24–168 小时。") }
        if !enabled {
            return ("if [ -x \(scheduler) ]; then \(scheduler) disable; else echo 'TimerEnabled=no'; fi", nil)
        }
        guard let resource = Bundle.main.url(forResource: "mentoglass_schedule", withExtension: "sh") else {
            throw RouterError.message("定时认证组件缺失，请使用完整 App 包。")
        }
        let script = try Data(contentsOf: resource)
        let command = """
        umask 077
        test -d /data/mentohust && test -x /etc/crontabs/patches/mentohust_boot.sh || exit 2
        NEW=$(mktemp /data/mentohust/.schedule.XXXXXX) || exit 3
        OLD=$(mktemp /tmp/mentoglass-cron.XXXXXX) || exit 3
        trap 'rm -f "$NEW" "$OLD" "$OLD.new"' EXIT HUP INT TERM
        cat > "$NEW" || exit 3
        sh -n "$NEW" || exit 3
        chmod 700 "$NEW"; mv "$NEW" \(scheduler) || exit 3
        if ! crontab -l > "$OLD" 2>/dev/null; then
          if [ -f /etc/crontabs/root ]; then cp /etc/crontabs/root "$OLD" || exit 3; else echo '无法读取现有定时任务，未覆盖。'; exit 3; fi
        fi
        cp "$OLD" /data/mentohust/mentoglass-crontab-backup || exit 3
        chmod 600 /data/mentohust/mentoglass-crontab-backup
        awk 'index($0,"# MentoGlass reauth")==0 {print}' "$OLD" > "$OLD.new" || exit 3
        printf '\\n* * * * * \(scheduler) run >/dev/null 2>&1 # MentoGlass reauth\\n' >> "$OLD.new"
        crontab "$OLD.new" || exit 3
        \(scheduler) \(installInactive ? "disable" : "enable \(hours)")
        """
        return (command, script)
    }

    // Persist a standard manufacturer-supported width. No reload when runtime already matches.
    static let fix160 = """
    test "$(uci -q get wireless.wifi1.type)" = qcawificfg80211 && test "$(uci -q get wireless.wifi1.country)" = CN || exit 2
    test "$(iw dev wl0 info 2>/dev/null | sed -n 's/.*width: \\([0-9]*\\) MHz.*/\\1/p')" = 160 || { echo '当前并非 160 MHz，未执行会中断 Wi-Fi 的操作。'; exit 3; }
    test -z "$(uci changes wireless)" || { echo '存在未保存的无线设置，未覆盖。'; exit 3; }
    umask 077
    test -f /data/mentohust/wireless-before-160.conf || cp /etc/config/wireless /data/mentohust/wireless-before-160.conf || exit 3
    chmod 600 /data/mentohust/wireless-before-160.conf
    uci set wireless.wifi1.bw='160' && uci set wireless.wifi1.htmode='HT160' && uci commit wireless || { uci revert wireless; exit 3; }
    echo '5 GHz 带宽已固定为 160 MHz。当前运行无需重启无线，DFS 保护保持开启。'
    \(readStatus)
    """

    static func saveRegion(_ code: String) throws -> (String, Data) {
        guard WirelessRegion.options.contains(where: { $0.code == code }) else {
            throw RouterError.message("请选择列表中的实际使用国家或地区。")
        }
        guard let resource = Bundle.main.url(forResource: "mentoglass_wireless_region", withExtension: "sh") else {
            throw RouterError.message("无线区域组件缺失，请使用完整 App 包。")
        }
        let command = """
        set -eu
        umask 077
        test "$(uci -q get wireless.wifi0.type)" = qcawificfg80211 && test "$(uci -q get wireless.wifi1.type)" = qcawificfg80211 || { echo '无线驱动不受支持。'; exit 2; }
        mkdir -p /data/mentoglass-wireless; chmod 700 /data/mentoglass-wireless
        NEW=$(mktemp /data/mentoglass-wireless/.region.XXXXXX)
        trap 'rm -f "$NEW"' EXIT HUP INT TERM
        cat > "$NEW"; sh -n "$NEW"; chmod 700 "$NEW"
        mv "$NEW" \(regionScript)
        \(regionScript) save \(code)
        \(readStatus)
        """
        return (command, try Data(contentsOf: resource))
    }
    static let applyRegion = """
    test -x \(regionScript) || { echo '请先保存区域。'; exit 2; }
    \(regionScript) apply
    """
}

enum DualWANCommands {
    static let base = "/data/mentoglass-dualwan"
    static let script = base + "/dualwan.sh"
    static let config = base + "/mentohus2.conf"
    static let status = """
    if [ -x \(script) ]; then
      echo 'DualInstalled=yes'
      \(script) status
      printf 'SecondUsername='; sed -n 's/^Username=//p' \(config)
    else echo 'DualInstalled=no'; fi
    """
    static let readPassword = """
    test -f \(config) || exit 2
    awk 'index($0,"="){i=index($0,"="); k=substr($0,1,i-1); gsub(/^[ \\t]+|[ \\t]+$/,"",k); if(k=="Password" || k=="EncodePass") print k "=" substr($0,i+1)}' \(config)
    """
    static let logs = """
    for f in /tmp/mentohus2.log /tmp/mentoglass-dhcp2.log; do
      printf '\\n──── 第二线路：%s ────\\n' "$f"
      if [ -f "$f" ]; then tail -n 140 "$f" | sed '/[Pp]assword/d;/[Pp]asswd/d;/[Ee]ncode[Pp]ass/d;/用户名/d;/密码/d'; else echo '暂无日志'; fi
    done
    """
    static func action(_ action: String) throws -> String {
        guard ["start", "stop", "restart", "balance-on", "balance-off", "hardware-on", "hardware-off"].contains(action) else {
            throw RouterError.message("不支持的第二线路操作。")
        }
        let operation: String
        if action == "restart" {
            operation = """
            BALANCED=no; test ! -f \(base)/balancing || BALANCED=yes
            \(script) stop
            sleep 2
            if pidof mentohus2 >/dev/null; then echo '旧的第二线路进程尚未退出，请稍后重试。'; exit 3; fi
            \(script) start
            test "$BALANCED" != yes || touch \(base)/balancing
            """
        } else { operation = "\(script) \(action)" }
        return """
        set -eu
        test -x \(script) || { echo '当前路由器尚未安装双线路管理。'; exit 2; }
        \(operation)
        sleep 2
        \(status)
        """
    }
    static func updateAccount(account: String, password: String) throws -> (String, Data) {
        guard !account.isEmpty, account.utf8.count <= 64,
              !account.contains(where: { $0.isNewline }), !account.contains("\0"),
              !password.contains(where: { $0.isNewline }), !password.contains("\0") else {
            throw RouterError.message("请检查第二账号与密码，不支持换行或空账号。")
        }
        var payload = "Username=\(account)\n"
        if !password.isEmpty { payload += "EncodePass=\(try CampusSecret.encode(password))\n" }
        let command = """
        set -eu
        umask 077
        CONF=\(config)
        test -f "$CONF" || exit 2
        PATCH=$(mktemp /tmp/mentoglass-second.XXXXXX)
        NEW=$(mktemp \(base)/.second-conf.XXXXXX)
        trap 'rm -f "$PATCH" "$NEW"' EXIT HUP INT TERM
        cat > "$PATCH"
        cp -p "$CONF" "$CONF.account-backup"
        chmod 600 "$CONF.account-backup"
        awk 'FILENAME==ARGV[1] {i=index($0,"="); k=substr($0,1,i-1); p[k]=substr($0,i+1); next} {i=index($0,"="); k=substr($0,1,i-1); if(k=="Password" && ("EncodePass" in p))next; if(k in p){print k "=" p[k]; done[k]=1}else{print}} END{for(k in p)if(!(k in done))print k "=" p[k]}' "$PATCH" "$CONF" > "$NEW"
        chmod 600 "$NEW"; mv "$NEW" "$CONF"
        echo '第二账号配置已保存，重新认证后生效。'
        \(status)
        """
        return (command, Data(payload.utf8))
    }
}
