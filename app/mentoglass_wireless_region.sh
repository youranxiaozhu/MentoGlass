#!/bin/sh
# Change only standard country codes. The vendor driver keeps regulatory enforcement.
set -eu
umask 077
BASE=/data/mentoglass-wireless
CONFIG=/etc/config/wireless
SCRIPT=/data/mentoglass-wireless/region.sh

country_id() {
  case "$1" in
    CN) echo 156;; HK) echo 344;; TW) echo 158;; US) echo 840;; CA) echo 124;;
    JP) echo 392;; KR) echo 410;; SG) echo 702;; AU) echo 36;; NZ) echo 554;;
    GB) echo 826;; DE) echo 276;; FR) echo 250;; RU) echo 643;; IN) echo 356;;
    TH) echo 764;; MY) echo 458;; ID) echo 360;; VN) echo 704;; BR) echo 76;;
    ZA) echo 710;; ES) echo 724;; IT) echo 380;; NL) echo 528;;
    *) echo '请选择列表中的实际使用国家或地区。' >&2; return 2;;
  esac
}
runtime_country() {
  value=$(iwpriv "$1" get_countrycode 2>/dev/null | sed -n 's/.*get_countrycode:[[:space:]]*\([0-9]*\).*/\1/p')
  case "$value" in ''|*[!0-9]*) echo unknown;; *) echo "$value";; esac
}
hash_config() { md5sum "$CONFIG" | awk '{print $1}'; }
supported() {
  [ "$(uci -q get wireless.wifi0.type)" = qcawificfg80211 ] &&
  [ "$(uci -q get wireless.wifi1.type)" = qcawificfg80211 ]
}
status() {
  echo 'WifiRegionInstalled=yes'
  printf 'WifiRegionSupported='; if supported; then echo yes; else echo no; fi
  printf 'WifiCountry0='; uci -q get wireless.wifi0.country || echo unknown
  printf 'WifiCountry1='; uci -q get wireless.wifi1.country || echo unknown
  printf 'WifiRuntimeCountry0ID='; runtime_country wl1 || true
  printf 'WifiRuntimeCountry1ID='; runtime_country wl0 || true
  printf 'WifiRegionPending='; if [ -f "$BASE/pending" ]; then
    target=$(cat "$BASE/pending"); expected=$(country_id "$target" 2>/dev/null || echo invalid)
    if [ "$(runtime_country wl0)" = "$expected" ] && [ "$(runtime_country wl1)" = "$expected" ]; then echo no; else echo yes; fi
  else echo no; fi
  printf 'WifiRegionJob='; job_state
}
job_state() {
  state=$(cat "$BASE/job-state" 2>/dev/null || echo none)
  case "$state" in queued|applying|restoring)
    pid=$(cat "$BASE/job-pid" 2>/dev/null || echo invalid)
    case "$pid" in ''|*[!0-9]*) echo interrupted; return;; esac
    if [ "$(cat "$BASE/job-boot" 2>/dev/null)" != "$(cat /proc/sys/kernel/random/boot_id)" ] || ! kill -0 "$pid" 2>/dev/null; then echo interrupted; return; fi
  esac
  echo "$state"
}
idle() {
  state=$(job_state)
  case "$state" in queued|applying|restoring) echo '无线区域任务正在执行，请等待后再刷新。' >&2; return 3;; esac
}
prepare() {
  supported || { echo '当前设备的无线驱动不受支持。' >&2; exit 2; }
  mkdir -p "$BASE"; chmod 700 "$BASE"
  exec 9>"$BASE/operation.lock"
  flock -n 9 || { echo '另一项无线区域操作正在执行。' >&2; exit 3; }
}

case "${1:-status}" in
  status) status;;
  save)
    country=${2:-}; country_id "$country" >/dev/null
    prepare; idle
    [ -z "$(uci changes wireless)" ] || { echo '存在未保存的无线设置，请先处理，未覆盖。' >&2; exit 3; }
    if [ -f "$BASE/pending" ] && [ "$(hash_config)" != "$(cat "$BASE/pending-hash")" ]; then
      echo '待应用期间无线配置被其他操作修改，请先检查，未覆盖。' >&2; exit 3
    fi
    if [ "$(uci -q get wireless.wifi0.country)" = "$country" ] && [ "$(uci -q get wireless.wifi1.country)" = "$country" ]; then
      echo '配置已是这个区域，没有更改或重启无线。'; status; exit 0
    fi
    oldhash=$(hash_config)
    stage=$(mktemp -d "$BASE/.stage.XXXXXX")
    new="$CONFIG.mentoglass-region-new"
    [ ! -e "$new" ] || { rmdir "$stage"; echo '临时无线配置已存在，未覆盖。' >&2; exit 3; }
    trap 'rm -f "$new"; rm -rf "$stage"' EXIT HUP INT TERM
    mkdir "$stage/delta"
    cp "$CONFIG" "$stage/wireless"
    uci -c "$stage" -P "$stage/delta" set "wireless.wifi0.country=$country"
    uci -c "$stage" -P "$stage/delta" set "wireless.wifi1.country=$country"
    uci -c "$stage" -P "$stage/delta" commit wireless
    [ "$(hash_config)" = "$oldhash" ] && [ -z "$(uci changes wireless)" ] || { echo '无线配置被其他操作修改，未覆盖。' >&2; exit 3; }
    # Multiple edits before applying retain the original recovery configuration.
    if [ ! -f "$BASE/pending" ]; then cp "$CONFIG" "$BASE/wireless-before-region.conf"; fi
    chmod 600 "$BASE/wireless-before-region.conf"
    cp "$stage/wireless" "$new"; chmod 600 "$new"
    mv "$new" "$CONFIG"
    hash_config > "$BASE/pending-hash"
    printf '%s\n' "$country" > "$BASE/pending"
    echo saved > "$BASE/job-state"
    echo '区域已保存；无线尚未重启，当前连接继续使用原区域。'
    status
    ;;
  apply)
    prepare; idle
    [ -f "$BASE/pending" ] && [ -f "$BASE/wireless-before-region.conf" ] || { echo '没有待应用的区域设置。' >&2; exit 2; }
    country=$(cat "$BASE/pending"); country_id "$country" >/dev/null
    [ -z "$(uci changes wireless)" ] && [ "$(hash_config)" = "$(cat "$BASE/pending-hash")" ] || { echo '保存后无线配置已改变，请重新检查并保存区域。' >&2; exit 3; }
    echo queued > "$BASE/job-state"
    cat /proc/sys/kernel/random/boot_id > "$BASE/job-boot"
    # The router has no nohup/setsid. Ignore HUP and detach all SSH streams.
    (exec 9>&-; trap '' HUP; sleep 3; exec /bin/sh "$SCRIPT" worker) </dev/null >/dev/null 2>&1 &
    echo "$!" > "$BASE/job-pid"
    echo '无线应用任务已排队。Wi-Fi 将断开，重新连接后请刷新状态。'
    status
    ;;
  worker)
    prepare
    [ "$(cat "$BASE/job-state")" = queued ] || exit 3
    [ -z "$(uci changes wireless)" ] && [ "$(hash_config)" = "$(cat "$BASE/pending-hash")" ] || { echo config-changed > "$BASE/job-state"; exit 3; }
    country=$(cat "$BASE/pending"); expected=$(country_id "$country")
    echo "$$" > "$BASE/job-pid"
    echo applying > "$BASE/job-state"
    # Vendor-supported wireless-only reload. Avoid the generic network reload.
    result=0; /sbin/wifi reload_legacy >/dev/null 2>&1 || result=$?
    if [ "$result" = 0 ] && [ "$(runtime_country wl0)" = "$expected" ] && [ "$(runtime_country wl1)" = "$expected" ]; then
      echo applied > "$BASE/job-state"
      rm -f "$BASE/pending" "$BASE/pending-hash"
    elif [ "$(hash_config)" = "$(cat "$BASE/pending-hash")" ] && [ -z "$(uci changes wireless)" ]; then
      echo restoring > "$BASE/job-state"
      cp "$BASE/wireless-before-region.conf" "$CONFIG.mentoglass-region-restore"
      chmod 600 "$CONFIG.mentoglass-region-restore"
      mv "$CONFIG.mentoglass-region-restore" "$CONFIG"
      if /sbin/wifi reload_legacy >/dev/null 2>&1; then echo rolled-back > "$BASE/job-state"; else echo rollback-failed > "$BASE/job-state"; fi
      rm -f "$BASE/pending" "$BASE/pending-hash"
    else
      echo failed-config-changed > "$BASE/job-state"
    fi
    ;;
  *) echo '不支持的无线区域操作。' >&2; exit 2;;
esac
