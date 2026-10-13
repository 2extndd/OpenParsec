#!/bin/bash
# Parsec host UDP straight out of the physical interface, past any VPN tunnel.
#
# A TUN VPN (Happ/xray, Hiddify/sing-box, V2Box, ...) re-sends each UDP flow
# from its own socket, so the address Parsec learns via STUN is not the one its
# peers see and NAT traversal fails (-6023) for every non-LAN client. With the
# host's ports (network_server_start_port 8000..) routed to the physical
# gateway and NATed back to its address with the same port, the mapping stays
# endpoint-independent whatever VPN runs. Without a VPN the rules match nothing.
#
#   sudo mac-helper/parsec-direct.sh install     # LaunchDaemon, at boot + network changes
#   sudo mac-helper/parsec-direct.sh uninstall
#   mac-helper/parsec-direct.sh apply            # what the daemon runs (root)
set -euo pipefail
LABEL=com.extnddos.openparsec.parsec-direct
DEST="/Library/Application Support/OpenParsec/parsec-direct.sh"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
ANCHOR="com.apple/250.OpenParsecDirect" # evaluated by the stock pf.conf (nat-anchor/anchor "com.apple/*")
PORTS="8000:8019"
LOCAL="{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4 }"
STATE=/var/run/openparsec-direct

# The default route that is not a tunnel: "<gateway> <interface>".
physical() { netstat -rn -f inet | awk '$1=="default" && $NF !~ /^(utun|ipsec|ppp|gif|stf)/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $2, $NF; exit}'; }

apply() {
  local cur gw if
  cur=$(physical || true)
  [[ -z "$cur" ]] && { pfctl -a "$ANCHOR" -F all 2>/dev/null || true; rm -f "$STATE.rules"; return; } # offline
  # Unchanged, still loaded and pf on: nothing to do (also re-applies if someone flushed pf).
  [[ "$cur" == "$(cat "$STATE.rules" 2>/dev/null)" ]] && pfctl -s info 2>/dev/null | grep -q "Status: Enabled" \
    && pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q route-to && return
  read -r gw if <<<"$cur"
  pfctl -a "$ANCHOR" -f - <<EOF
nat on $if inet proto udp from ! ($if) port $PORTS to ! $LOCAL -> ($if) static-port
pass out quick on ! $if route-to ($if $gw) inet proto udp from any port $PORTS to ! $LOCAL keep state
EOF
  # pf stays enabled while this token is held (released on uninstall).
  pfctl -s info 2>/dev/null | grep -q "Status: Enabled" || pfctl -E 2>&1 | awk '/Token/{print $NF}' >"$STATE.token"
  echo "$cur" >"$STATE.rules"
  logger -t parsec-direct "rules for $if via $gw"
}

case "${1:-apply}" in
apply) apply ;;
install)
  mkdir -p "$(dirname "$DEST")"
  install -m 755 "$0" "$DEST"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$DEST</string><string>apply</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>15</integer>
	<key>WatchPaths</key><array><string>/Library/Preferences/SystemConfiguration</string></array>
</dict>
</plist>
EOF
  launchctl bootout system/$LABEL 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
  sleep 1; pfctl -a "$ANCHOR" -s nat; pfctl -a "$ANCHOR" -s rules
  echo "installed" ;;
uninstall)
  launchctl bootout system/$LABEL 2>/dev/null || true
  pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  [[ -s "$STATE.token" ]] && pfctl -X "$(cat "$STATE.token")" 2>/dev/null || true
  rm -f "$PLIST" "$DEST" "$STATE.rules" "$STATE.token"
  echo "uninstalled" ;;
*) echo "usage: $0 [apply|install|uninstall]" >&2; exit 2 ;;
esac
