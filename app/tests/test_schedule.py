"""Local simulation only. Never contacts a router or campus network."""
from pathlib import Path
import os
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1] / "mentoglass_schedule.sh"
with tempfile.TemporaryDirectory(prefix="mentoglass-schedule-test-") as tmp:
    root = Path(tmp)
    base = root / "data"
    tools = root / "bin"
    base.mkdir()
    tools.mkdir()
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o700)
    executable(tools / "date", '#!/bin/sh\necho "$TEST_NOW"\n')
    executable(tools / "sleep", "#!/bin/sh\nexit 0\n")
    executable(tools / "pidof", f'#!/bin/sh\n[ -f "{root}/pid" ] || exit 1\ncat "{root}/pid"\n')
    executable(base / "mentohust", "#!/bin/sh\nexit 0\n")
    executable(root / "boot", f'''#!/bin/sh
case "$1" in
 stop) [ "$TEST_STUCK" = 1 ] || rm -f "{root}/pid";;
 start) echo 222 > "{root}/pid"; echo start >> "{root}/calls";;
esac
''')
    local = source.read_text().replace("BASE=/data/mentohust", f"BASE='{base}'")
    local = local.replace("BOOT=/etc/crontabs/patches/mentohust_boot.sh", f"BOOT='{root}/boot'")
    local = local.replace("LOCK=/tmp/mentoglass-schedule.lock", f"LOCK='{root}/lock'")
    local = local.replace("/sys/class/net/eth0/carrier", str(root / "carrier"))
    executable(root / "schedule", local)
    env = os.environ.copy()
    env.update(PATH=str(tools) + ":/usr/bin:/bin", TEST_NOW="1800000000", TEST_STUCK="0")
    def run(*args, now=1800000000, expected=0):
        env["TEST_NOW"] = str(now)
        result = subprocess.run(["/bin/sh", str(root / "schedule"), *args], env=env, capture_output=True, text=True)
        assert result.returncode == expected, (args, result.returncode, result.stderr)
        return result.stdout
    def starts():
        return (root / "calls").read_text().count("start") if (root / "calls").exists() else 0
    def next_time():
        return int((base / "mentoglass-schedule-next").read_text())
    def due():
        (base / "mentoglass-schedule-next").write_text("1800000000\n")
    (base / "enabled").touch()
    (root / "carrier").write_text("1\n")
    (root / "pid").write_text("111\n")
    assert "TimerEnabled=no" in run("status")
    run("run")
    assert starts() == 0
    run("enable", "24")
    assert next_time() == 1800000000 + 86400
    run("run", now=1800086399)
    assert starts() == 0
    run("run", now=1800086400)
    assert starts() == 1 and next_time() == 1800172800
    run("run", now=1800086400)
    assert starts() == 1, "Repeated cron tick caused a second authentication"
    run("disable")
    run("run", now=1801000000)
    assert starts() == 1
    run("enable", "1", expected=2)
    run("enable", "169", expected=2)
    run("enable", "24", now=100, expected=3)
    assert not (base / "mentoglass-schedule-enabled").exists()
    run("enable", "48")
    assert next_time() == 1800172800
    due()
    (base / "enabled").unlink()
    run("run")
    assert starts() == 1 and "守护已关闭" in (base / "mentoglass-schedule-state").read_text()
    (base / "enabled").touch()
    due()
    (root / "carrier").write_text("0\n")
    run("run")
    assert starts() == 1 and "WAN 未连接" in (base / "mentoglass-schedule-state").read_text()
    (root / "carrier").write_text("1\n")
    due()
    env["TEST_STUCK"] = "1"
    run("run")
    assert starts() == 1 and "旧进程" in (base / "mentoglass-schedule-state").read_text()
    env["TEST_STUCK"] = "0"
    due()
    (root / "lock").mkdir()
    (root / "lock" / "pid").write_text(str(os.getpid()))
    run("run")
    assert starts() == 1 and next_time() == 1800000000
    (root / "lock" / "pid").write_text("99999999")
    run("run")
    assert starts() == 2 and not (root / "lock").exists()
    due()
    run("run", now=100)
    assert starts() == 2 and next_time() == 1800000000
    run("run", now=1801000000)
    assert starts() == 3 and next_time() == 1801000000 + 172800, "Missed intervals caused catch-up burst"
    run("run", now=1801000000)
    assert starts() == 3
print("PASS: local scheduler timing, OFF state, interval limits, clock guard, WAN/daemon skips, single execution, lock recovery, no catch-up burst.")
