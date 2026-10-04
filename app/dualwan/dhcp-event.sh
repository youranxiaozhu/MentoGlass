#!/bin/sh
# DHCP replies apply only to LAN1's routed VLAN, never to the private bridge or WAN1.
set -eu
umask 077
BASE=/data/mentoglass-dualwan
IF=eth1.3
[ "${interface:-}" = "$IF" ] || exit 1
case "${1:-}" in
  deconfig)
    rm -f "$BASE/lease"
    "$BASE/dualwan.sh" pause >/dev/null 2>&1 || true
    ip -4 addr flush dev "$IF" scope global
    ;;
  bound|renew)
    valid_ip() { echo "$1" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/ || $i>255)exit 1}'; }
    valid_ip "${ip:-}"; valid_ip "${subnet:-}"
    gw=${router%% *}; valid_ip "$gw"
    # Require a contiguous IPv4 mask and derive its network prefix without eval.
    calc=$(awk -v address="$ip" -v mask="$subnet" 'BEGIN {
      split(address,a,"."); split(mask,m,"."); bits=0; zero=0;
      for(i=1;i<=4;i++) {v=m[i]+0; n[i]=0; weight=128;
        for(j=1;j<=8;j++) {one=int(v/weight)%2;
          if(one) {if(zero)exit 1;bits++; if(int(a[i]/weight)%2)n[i]+=weight;} else zero=1;
          weight/=2;
        }
      }
      if(bits<1 || bits>30)exit 1;
      printf "%d %d.%d.%d.%d/%d",bits,n[1],n[2],n[3],n[4],bits;
    }')
    prefix=${calc%% *}; network=${calc#* }
    firstip=$(ip -4 addr show dev eth0 | awk '/inet /{split($2,a,"/");print a[1];exit}')
    [ "$ip" != "$firstip" ] || { logger -t MentoGlass 'Second WAN received duplicate first-WAN address; refused.'; exit 1; }
    oldip=''
    [ ! -f "$BASE/lease" ] || oldip=$(sed -n 's/^ip=//p' "$BASE/lease")
    if [ -n "$oldip" ] && [ "$oldip" != "$ip" ]; then ip -4 addr flush dev "$IF" scope global; fi
    # This firmware's old ip tool lacks noprefixroute. Remove ONLY this interface's
    # automatically created subnet route; WAN1's main routes remain untouched.
    ip -4 addr replace "$ip/$prefix" dev "$IF"
    ip -4 route del "$network" dev "$IF" table main 2>/dev/null || true
    ip -4 route replace "$network" dev "$IF" src "$ip" table 202
    ip -4 route replace 192.168.31.0/24 dev br-lan table 202
    ip -4 route replace default via "$gw" dev "$IF" src "$ip" table 202
    if [ -n "$oldip" ] && [ "$oldip" != "$ip" ]; then
      ip -4 rule del pref 1202 from "$oldip/32" table 202 2>/dev/null || true
    fi
    ip -4 rule show | grep -q "^1202:.*from $ip.*lookup 202" || ip -4 rule add pref 1202 from "$ip/32" table 202
    now=$(date +%s)
    lifetime=${lease:-3600}; case "$lifetime" in ''|*[!0-9]*) lifetime=3600;; esac
    { printf 'ip=%s\nnetwork=%s\ngateway=%s\nexpires=%s\n' "$ip" "$network" "$gw" "$((now+lifetime))"; } > "$BASE/lease.new"
    chmod 600 "$BASE/lease.new"; mv "$BASE/lease.new" "$BASE/lease"
    logger -t MentoGlass 'Second WAN DHCP lease installed in isolated route table.'
    ;;
esac
