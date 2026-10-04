#!/bin/sh
# Reapply only our own isolated interface rules after a normal firewall reload.
exec /data/mentoglass-dualwan/dualwan.sh firewall
