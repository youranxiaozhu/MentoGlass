#!/bin/sh
# Read-only preflight, intended to run on the user's own router via SSH stdin.
# No account reads, configuration changes, authentication or network probes.
missing=0
check_file() {
  if [ -f "$1" ]; then printf 'PASS file %s\n' "$1";
  else printf 'MISSING file %s\n' "$1"; missing=$((missing+1)); fi
}
check_exec() {
  if [ -x "$1" ]; then printf 'PASS executable %s\n' "$1";
  else printf 'MISSING executable %s\n' "$1"; missing=$((missing+1)); fi
}
check_exec /data/mentohust/mentohust
check_file /data/mentohust/mentohust.conf
check_exec /etc/crontabs/patches/mentohust_boot.sh
for tool in uci ip iptables swconfig ubus jsonfilter iwpriv crontab flock; do
  if command -v "$tool" >/dev/null 2>&1; then printf 'PASS command %s\n' "$tool";
  else printf 'MISSING command %s\n' "$tool"; fi
done
printf 'Kernel='; uname -r
printf 'CPU-facing WAN carrier='; cat /sys/class/net/eth0/carrier 2>/dev/null || echo unavailable
if command -v swconfig >/dev/null 2>&1; then
  swconfig dev switch1 port 4 get link 2>/dev/null || true
  swconfig dev switch1 port 3 get link 2>/dev/null || true
fi
if command -v uci >/dev/null 2>&1; then
  printf '5GHz driver='; uci -q get wireless.wifi1.type || echo unavailable
  printf '5GHz width='; uci -q get wireless.wifi1.bw || echo unavailable
fi
if [ -x /data/mentoglass-dualwan/dualwan.sh ]; then
  echo 'Dual-WAN component=installed'
else echo 'Dual-WAN component=not installed (optional)'; fi
echo 'This check does not verify Internet access or authenticate.'
[ "$missing" = 0 ]

