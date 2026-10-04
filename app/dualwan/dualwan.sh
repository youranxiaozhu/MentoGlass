#!/bin/sh
set -eu
umask 077
BASE=/data/mentoglass-dualwan
IF=eth1.3
MASK=0x300
M1=0x100
M2=0x200

ipt() { iptables -w "$@"; }
have_chain() { ipt -t "$1" -nL "$2" >/dev/null 2>&1; }
ensure_chain() { have_chain "$1" "$2" || ipt -t "$1" -N "$2"; }
add_once() { table=$1; shift; ipt -t "$table" -C "$@" 2>/dev/null || ipt -t "$table" -A "$@"; }
insert_once() { table=$1; shift; ipt -t "$table" -C "$@" 2>/dev/null || ipt -t "$table" -I "$@"; }
apply_acceleration() {
  if [ -w /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode ]; then
    [ -f "$BASE/ecm-original" ] || cat /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode > "$BASE/ecm-original"
    # ECM enum: 0=don't care, 1=deny acceleration, 2=allow acceleration.
    # Opt in only after validating both accelerated egress paths on this router.
    mode=1
    if [ -f "$BASE/hardware-acceleration-verified" ] && [ -f "$BASE/hardware-acceleration-enabled" ]; then mode=2; fi
    echo "$mode" > /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode
  fi
}

firewall() {
  # Prepare complete dedicated chains before removing the previous staging DROP rules.
  ensure_chain filter MG2_INPUT
  add_once filter MG2_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  add_once filter MG2_INPUT -p udp --sport 67 --dport 68 -j ACCEPT
  add_once filter MG2_INPUT -j DROP
  ensure_chain filter MG2_FORWARD
  add_once filter MG2_FORWARD -i "$IF" -o br-lan -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  add_once filter MG2_FORWARD -i br-lan -o "$IF" -s 192.168.31.0/24 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  add_once filter MG2_FORWARD -j DROP
  insert_once filter INPUT -i "$IF" -j MG2_INPUT
  insert_once filter FORWARD -i "$IF" -j MG2_FORWARD
  insert_once filter FORWARD -o "$IF" -j MG2_FORWARD
  # Router-originated packets use the normal OUTPUT policy after staging is removed.
  for chain in INPUT FORWARD; do
    while ipt -C "$chain" -i "$IF" -j DROP 2>/dev/null; do ipt -D "$chain" -i "$IF" -j DROP; done
  done
  for chain in OUTPUT FORWARD; do
    while ipt -C "$chain" -o "$IF" -j DROP 2>/dev/null; do ipt -D "$chain" -o "$IF" -j DROP; done
  done
  insert_once nat POSTROUTING -s 192.168.31.0/24 -o "$IF" -j MASQUERADE
  ensure_chain mangle MG_BALANCE
  # Existing sessions that predate setup stay on WAN1. Mark only new connections.
  ensure_chain mangle MG_SELECT
  add_once mangle MG_SELECT -m mark --mark 0/$MASK -m statistic --mode random --probability 0.5 -j MARK --set-xmark $M2/$MASK
  add_once mangle MG_SELECT -m mark --mark 0/$MASK -j MARK --set-xmark $M1/$MASK
  add_once mangle MG_SELECT -j CONNMARK --save-mark --nfmask $MASK --ctmask $MASK
  ensure_chain mangle MG_POLICY
  add_once mangle MG_POLICY -m addrtype --dst-type LOCAL -j RETURN
  for range in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    add_once mangle MG_POLICY -d "$range" -j RETURN
  done
  add_once mangle MG_POLICY -j CONNMARK --restore-mark --nfmask $MASK --ctmask $MASK
  add_once mangle MG_POLICY -m mark ! --mark 0/$MASK -j RETURN
  add_once mangle MG_POLICY -m conntrack --ctstate NEW -j MG_BALANCE
  insert_once mangle PREROUTING -i br-lan -s 192.168.31.0/24 -j MG_POLICY
  if [ -f "$BASE/balancing" ] && second_ready; then set_balance on; else set_balance off; fi
}

second_ready() {
  pidof mentohus2 >/dev/null || return 1
  [ -f "$BASE/lease" ] || return 1
  leaseip=$(sed -n 's/^ip=//p' "$BASE/lease")
  ip -4 addr show dev "$IF" | awk -v target="$leaseip" '/inet /{split($2,a,"/");if(a[1]==target)found=1} END{exit !found}' || return 1
  [ "$(cat /sys/class/net/eth1/carrier 2>/dev/null)" = 1 ] || return 1
  swconfig dev switch1 port 3 get link | grep -q 'link:up' || return 1
  expiry=$(sed -n 's/^expires=//p' "$BASE/lease")
  case "$expiry" in ''|*[!0-9]*) return 1;; esac
  [ "$(date +%s)" -lt "$expiry" ] || return 1
  # The DHCP script only runs after successful EAP authentication in mode2.
  ip -4 route show table 202 | grep -q '^default ' || return 1
}

first_ready() {
  pidof mentohust >/dev/null || return 1
  [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ] || return 1
  # eth0 is the CPU-facing link: it can stay up after the campus cable is unplugged.
  swconfig dev switch1 port 4 get link | grep -q 'link:up' || return 1
  [ "$(ubus call network.interface.wan status | jsonfilter -e '@.up')" = true ]
}

isolate_arp() {
  # Both campus interfaces share a subnet. Announce only an address belonging
  # to the transmitting interface; do not change global or private-LAN settings.
  for dev in eth0 "$IF"; do
    for setting in arp_ignore:1 arp_announce:2; do
      key=${setting%:*}; value=${setting#*:}
      path=/proc/sys/net/ipv4/conf/$dev/$key
      if [ -w "$path" ] && [ "$(cat "$path")" != "$value" ]; then echo "$value" > "$path"; fi
    done
  done
}

set_balance() {
  ensure_chain mangle MG_BALANCE
  if [ "$1" = on ]; then
    ensure_chain mangle MG_ONLY2
    add_once mangle MG_ONLY2 -m mark --mark 0/$MASK -j MARK --set-xmark $M2/$MASK
    add_once mangle MG_ONLY2 -j CONNMARK --save-mark --nfmask $MASK --ctmask $MASK
    if first_ready; then target=MG_SELECT; other=MG_ONLY2; else target=MG_ONLY2; other=MG_SELECT; fi
    # Insert the new selector first. A following old selector cannot overwrite a
    # nonzero mark, so switching modes never leaves an unmarked selection gap.
    insert_once mangle MG_BALANCE -j "$target"
    while ipt -t mangle -C MG_BALANCE -j "$other" 2>/dev/null; do ipt -t mangle -D MG_BALANCE -j "$other"; done
  else
    for target in MG_SELECT MG_ONLY2; do
      while ipt -t mangle -C MG_BALANCE -j "$target" 2>/dev/null; do ipt -t mangle -D MG_BALANCE -j "$target"; done
    done
  fi
}

route_first() (
  # Reuse netifd's current WAN1 routes without changing the main routing table.
  # Serialize route updates, including simultaneous GUI and maintenance calls.
  exec 8>"$BASE/route-first.lock"
  flock 8
  stage=$(mktemp -d "$BASE/.route-first.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  ip -4 route show table main dev eth0 > "$stage/main"
  [ -s "$stage/main" ] || exit 1
  while IFS= read -r line; do
    case "$line" in ''|*'nexthop'*) continue;; esac
    # Route text is generated by ip, contains only routing fields, no account data.
    # ip's filtered output omits dev, so add the selected interface explicitly.
    ip -4 route replace table 201 $line dev eth0
  done < "$stage/main"
  ip -4 route replace 192.168.31.0/24 dev br-lan table 201
  # Install current routes first, then remove old prefix/metric entries left by
  # an address or gateway change. A concurrent DHCP change postpones pruning.
  ip -4 route show table main dev eth0 > "$stage/check"
  if cmp -s "$stage/main" "$stage/check"; then
    awk '{metric=0; for(i=2;i<NF;i++)if($i=="metric")metric=$(i+1); print $1 "|" metric}' "$stage/main" > "$stage/keys"
    ip -4 route show table 201 dev eth0 > "$stage/old"
    while IFS= read -r line; do
      case "$line" in ''|*'nexthop'*) continue;; esac
      key=$(printf '%s\n' "$line" | awk '{metric=0;for(i=2;i<NF;i++)if($i=="metric")metric=$(i+1);print $1 "|" metric}')
      if ! grep -Fxq "$key" "$stage/keys"; then
        ip -4 route del table 201 $line dev eth0 2>/dev/null || true
      fi
    done < "$stage/old"
  fi
  ip -4 rule show | grep -q '^1101:.*fwmark 0x100/0x300.*lookup 201' || ip -4 rule add pref 1101 fwmark $M1/$MASK table 201
  ip -4 rule show | grep -q '^1102:.*fwmark 0x200/0x300.*lookup 202' || ip -4 rule add pref 1102 fwmark $M2/$MASK table 202
)

prepare() {
  [ "$(swconfig dev switch1 vlan 1 get ports | xargs)" = '1 2 6' ]
  [ "$(swconfig dev switch1 vlan 2 get ports | xargs)" = '4 5' ]
  [ "$(swconfig dev switch1 vlan 3 get ports | xargs)" = '3 6t' ]
  [ -d /sys/class/net/"$IF" ] || ip link add link eth1 name "$IF" type vlan id 3
  [ ! -e /sys/class/net/"$IF"/master ]
  [ ! -e /proc/sys/net/ipv6/conf/"$IF"/disable_ipv6 ] || echo 1 > /proc/sys/net/ipv6/conf/"$IF"/disable_ipv6
  isolate_arp
  firewall
  echo 0 > /proc/sys/net/ipv4/conf/"$IF"/rp_filter
  echo 1 > /proc/sys/net/ipv4/conf/"$IF"/arp_ignore
  echo 2 > /proc/sys/net/ipv4/conf/"$IF"/arp_announce
  ip link set dev "$IF" up
}

case "${1:-status}" in
  prepare) prepare;;
  start)
    prepare
    if pidof mentohus2 >/dev/null; then echo '第二账号进程已经运行。'; exit 0; fi
    [ -f "$BASE/mentohus2.conf" ]
    set_balance off
    rm -f "$BASE/lease"
    ln -sf "$BASE/mentohus2.conf" /etc/mentohus2.conf
    touch /tmp/mentoglass-dualwan-boot-attempt
    touch "$BASE/enabled"
    "$BASE/mentohus2" > /tmp/mentoglass-auth2-start.log 2>&1
    ;;
  stop)
    rm -f "$BASE/enabled"
    rm -f "$BASE/balancing"
    set_balance off
    if pidof mentohus2 >/dev/null; then "$BASE/mentohus2" -k >/dev/null 2>&1; fi
    if [ -f /tmp/mentoglass-udhcpc2.pid ]; then
      p=$(cat /tmp/mentoglass-udhcpc2.pid)
      case "$p" in ''|*[!0-9]*) :;; *)
        if [ -r "/proc/$p/cmdline" ] && tr '\000' ' ' < "/proc/$p/cmdline" | grep -q 'udhcpc.*eth1.3'; then kill "$p"; fi;;
      esac
    fi
    ip link set dev "$IF" down
    ip -4 addr flush dev "$IF" scope global
    rm -f "$BASE/lease"
    echo '第二线路已停止，新的连接继续使用原 WAN。'
    ;;
  balance-on)
    second_ready || { echo '第二线路尚未认证并取得有效地址，未开启分流。'; exit 2; }
    route_first
    apply_acceleration
    touch "$BASE/balancing"
    set_balance on
    echo '双线路按新连接进行 1:1 分流；已有连接保持原线路。'
    ;;
  balance-off)
    rm -f "$BASE/balancing"
    set_balance off
    if [ -f "$BASE/ecm-original" ] && [ -w /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode ]; then
      cat "$BASE/ecm-original" > /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode
    fi
    echo '已关闭双线路分流。'
    ;;
  pause)
    # Lease loss pauses selection but retains the user's saved switch preference.
    set_balance off
    ;;
  hardware-on)
    [ -f "$BASE/hardware-acceleration-verified" ] && [ -w /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode ] || { echo '这台路由器尚未验证双线路硬件加速。'; exit 2; }
    [ -f "$BASE/balancing" ] && second_ready || { echo '请先让双线路分流就绪。'; exit 2; }
    route_first
    touch "$BASE/hardware-acceleration-enabled"
    apply_acceleration
    echo '双线路硬件加速已开启，认证进程保持运行。'
    ;;
  hardware-off)
    rm -f "$BASE/hardware-acceleration-enabled"
    if [ -f "$BASE/balancing" ]; then
      apply_acceleration
      # Invalidate ECM flow cache, preserving Linux conntrack and authentication.
      [ ! -w /sys/kernel/debug/ecm/ecm_db/defunct_all ] || echo 1 > /sys/kernel/debug/ecm/ecm_db/defunct_all
    fi
    echo '双线路硬件加速已关闭，分流继续使用软件转发。'
    ;;
  maintain)
    # No authentication retries and no network probes. Only local process/lease/link checks.
    isolate_arp
    # After an actual reboot, attempt normal authentication ONCE when the switch is ready.
    if [ -f "$BASE/enabled" ] && [ ! -f /tmp/mentoglass-dualwan-boot-attempt ]; then
      if [ "$(swconfig dev switch1 vlan 3 get ports | xargs)" = '3 6t' ]; then
        touch /tmp/mentoglass-dualwan-boot-attempt
        "$0" start >/tmp/mentoglass-auth2-boot.log 2>&1 || true
      fi
    fi
    if [ -f "$BASE/balancing" ]; then
      if second_ready; then route_first; apply_acceleration; set_balance on; else set_balance off; fi
    else
      set_balance off
    fi
    ;;
  firewall)
    [ -d /sys/class/net/"$IF" ] && firewall || true
    ;;
  status)
    printf 'SecondRunning='; if pidof mentohus2 >/dev/null; then echo yes; else echo no; fi
    printf 'SecondReady='; if second_ready; then echo yes; else echo no; fi
    printf 'BalanceEnabled='; if [ -f "$BASE/balancing" ]; then echo yes; else echo no; fi
    printf 'BalanceActive='; if ipt -t mangle -C MG_BALANCE -j MG_SELECT 2>/dev/null || ipt -t mangle -C MG_BALANCE -j MG_ONLY2 2>/dev/null; then echo yes; else echo no; fi
    printf 'BalanceMode='; if ipt -t mangle -C MG_BALANCE -j MG_SELECT 2>/dev/null; then echo balanced; elif ipt -t mangle -C MG_BALANCE -j MG_ONLY2 2>/dev/null; then echo second-only; else echo paused; fi
    printf 'SecondIP='; if [ -f "$BASE/lease" ]; then sed -n 's/^ip=//p' "$BASE/lease"; else echo ''; fi
    printf 'SecondInterface=%s\n' "$IF"
    printf 'HardwareAccelerationSupported='; if [ -f "$BASE/hardware-acceleration-verified" ] && [ -w /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode ]; then echo yes; else echo no; fi
    printf 'HardwareAccelerationEnabled='; if [ -f "$BASE/hardware-acceleration-enabled" ]; then echo yes; else echo no; fi
    printf 'HardwareAccelerationMode='; cat /sys/kernel/debug/ecm/ecm_classifier_default/accel_mode 2>/dev/null || echo unknown
    printf 'HardwareAcceleratedConnections='; cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count 2>/dev/null || echo unknown
    ;;
  *) echo 'Unsupported dual-WAN action'; exit 2;;
esac
