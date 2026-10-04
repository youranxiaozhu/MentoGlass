#!/bin/sh
# One normal reauthentication per interval. No probes, scans, floods or catch-up loops.
umask 077
BASE=/data/mentohust
BOOT=/etc/crontabs/patches/mentohust_boot.sh
BIN="$BASE/mentohust"
LOCK=/tmp/mentoglass-schedule.lock
STATE="$BASE/mentoglass-schedule-state"
NOW=$(date +%s)

valid_number() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
read_value() { [ -f "$1" ] && cat "$1"; }
write_atomic() { umask 077; printf '%s\n' "$2" > "$1.tmp.$$" && mv "$1.tmp.$$" "$1"; }
status() {
    if [ -f "$BASE/mentoglass-schedule-enabled" ]; then echo 'TimerEnabled=yes'; else echo 'TimerEnabled=no'; fi
    echo "TimerHours=$(read_value "$BASE/mentoglass-schedule-hours")"
    echo "TimerNext=$(read_value "$BASE/mentoglass-schedule-next")"
    echo "TimerLast=$(read_value "$BASE/mentoglass-schedule-last")"
    echo "TimerResult=$(read_value "$STATE")"
}

case "$1" in
    status) status; exit 0;;
    disable) rm -f "$BASE/mentoglass-schedule-enabled"; status; exit 0;;
    enable)
        HOURS="$2"
        valid_number "$HOURS" && [ "$HOURS" -ge 24 ] && [ "$HOURS" -le 168 ] || exit 2
        valid_number "$NOW" && [ "$NOW" -ge 1700000000 ] || { echo '路由器时钟尚未校准，未启用定时认证。'; exit 3; }
        write_atomic "$BASE/mentoglass-schedule-hours" "$HOURS" || exit 3
        write_atomic "$BASE/mentoglass-schedule-next" "$((NOW + HOURS * 3600))" || exit 3
        touch "$BASE/mentoglass-schedule-enabled" || exit 3
        status; exit 0;;
    run) ;;
    *) exit 2;;
esac

[ -f "$BASE/mentoglass-schedule-enabled" ] || exit 0
HOURS=$(read_value "$BASE/mentoglass-schedule-hours")
NEXT=$(read_value "$BASE/mentoglass-schedule-next")
valid_number "$HOURS" && [ "$HOURS" -ge 24 ] && [ "$HOURS" -le 168 ] || exit 2
valid_number "$NOW" && [ "$NOW" -ge 1700000000 ] || exit 0
valid_number "$NEXT" && [ "$NOW" -ge "$NEXT" ] || exit 0

if ! mkdir "$LOCK" 2>/dev/null; then
    OWNER=$(read_value "$LOCK/pid")
    valid_number "$OWNER" || exit 0
    kill -0 "$OWNER" 2>/dev/null && exit 0
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo "$$" > "$LOCK/pid"
trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null' EXIT
trap 'exit 0' HUP INT TERM
# Recheck state inside the lock; consume the slot before any authentication action.
[ -f "$BASE/mentoglass-schedule-enabled" ] || exit 0
NEXT=$(read_value "$BASE/mentoglass-schedule-next")
valid_number "$NEXT" && [ "$NOW" -ge "$NEXT" ] || exit 0
write_atomic "$BASE/mentoglass-schedule-next" "$((NOW + HOURS * 3600))" || exit 3
write_atomic "$BASE/mentoglass-schedule-last" "$NOW" || exit 3

if [ ! -f "$BASE/enabled" ]; then
    write_atomic "$STATE" '认证守护已关闭，本次跳过'
    exit 0
fi
if [ ! -x "$BOOT" ] || [ ! -x "$BIN" ]; then
    write_atomic "$STATE" '认证程序或控制脚本不存在，本次跳过'
    exit 0
fi
if [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" != 1 ]; then
    write_atomic "$STATE" 'WAN 未连接，本次跳过'
    exit 0
fi

BEFORE=$(pidof mentohust 2>/dev/null)
"$BOOT" stop >/dev/null 2>&1
sleep 2
if pidof mentohust >/dev/null 2>&1; then
    write_atomic "$STATE" '旧进程未正常退出，本次跳过重新启动'
    exit 0
fi
[ -f "$BASE/mentoglass-schedule-enabled" ] && [ -f "$BASE/enabled" ] || exit 0
"$BOOT" start >/dev/null 2>&1
sleep 2
AFTER=$(pidof mentohust 2>/dev/null)
if [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ]; then
    write_atomic "$STATE" '认证进程已重新启动，外网需另行确认'
else
    write_atomic "$STATE" '认证进程未启动，请查看认证日志'
fi
