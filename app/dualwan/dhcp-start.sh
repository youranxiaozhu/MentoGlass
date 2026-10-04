#!/bin/sh
set -eu
umask 077
BASE=/data/mentoglass-dualwan
PID=/tmp/mentoglass-udhcpc2.pid
if [ -f "$PID" ]; then
  p=$(cat "$PID")
  case "$p" in ''|*[!0-9]*) exit 1;; esac
  if [ -r "/proc/$p/cmdline" ] && tr '\000' ' ' < "/proc/$p/cmdline" | grep -q 'udhcpc.*eth1.3'; then
    kill -USR1 "$p"
    exit 0
  fi
fi
# One ordinary DHCP attempt, at most three discovers. -n exits if it cannot lease.
# Successful acquisition backgrounds the client for normal lease renewals.
udhcpc -n -t 3 -T 3 -i eth1.3 -p "$PID" -s "$BASE/dhcp-event.sh" -C > /tmp/mentoglass-dhcp2.log 2>&1
