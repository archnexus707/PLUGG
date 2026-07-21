#!/usr/bin/env bash
#===============================================================================
#   ██████╗ ██╗     ██╗   ██╗ ██████╗  ██████╗
#   PLUGG  ·  THE WiFi PLUG        crafted by @archnexus707
#-------------------------------------------------------------------------------
#   Auto internet-sharing hotspot. Detects the ALFA's current WiFi (HOPE today,
#   anything tomorrow), asks a few questions, and shares it out a 2nd radio as a
#   secured WPA2/WPA3 AP. Dual-band aware. Self-heals. QR-code join.
#   Everything (routing / firewall / NAT / NetworkManager) auto-restores on exit.
#
#   Features:  ⚡ AUTO  📱 QR join  📡 auto-channel  💚 watchdog
#              📊 live bandwidth  💾 named profiles  🛡 guest isolation
#===============================================================================
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="/run/plugg"
PROFILE_DIR="$SCRIPT_DIR/profiles"
CONF_FILE="$SCRIPT_DIR/plugg.conf"
HOSTAPD_CONF="$RUN_DIR/hostapd.conf"; DNSMASQ_CONF="$RUN_DIR/dnsmasq.conf"
HOSTAPD_PID="$RUN_DIR/hostapd.pid";   DNSMASQ_PID="$RUN_DIR/dnsmasq.pid"
LEASE_FILE="$RUN_DIR/dnsmasq.leases"; STATE_FILE="$RUN_DIR/state.env"
WATCHDOG_PID="$RUN_DIR/watchdog.pid"
LOG_FILE="$SCRIPT_DIR/plugg.log"
NFT_TABLE="plugg"; RT_TABLE="200"

DEF_SSID="PLUGG_NET"; DEF_PASS="Plugg12345"; DEF_SUBNET="10.42.0"
DEF_CHANNEL="6"; DEF_BAND="bg"; DEF_HW="g"; DEF_WPA_MODE="2"; DEF_ISOLATE="yes"
DEF_AUTOCHAN="yes"; DEF_WATCHDOG="yes"; DEF_MAXSTA="0"; DEF_OFFMINS="0"

HOSTAPD_CTL="$RUN_DIR/hostapd_ctl"; DENY_FILE="$RUN_DIR/hostapd.deny"
AUTOOFF_PID="$RUN_DIR/autooff.pid"

STARTED_SESSION=0; CLEANED=0; DASH_STOP=0
PREV_RX=0; PREV_TX=0; PREV_T=0

if [ -t 1 ]; then
  R=$'\e[38;5;196m'; G=$'\e[38;5;46m'; Y=$'\e[38;5;226m'; C=$'\e[38;5;51m'
  M=$'\e[38;5;201m'; O=$'\e[38;5;208m'; GR=$'\e[38;5;245m'; W=$'\e[1m'; N=$'\e[0m'
else R=; G=; Y=; C=; M=; O=; GR=; W=; N=; fi

log(){ echo "[$(date '+%F %T')] $*" >>"$LOG_FILE" 2>/dev/null; }
info(){ echo "${C}[*]${N} $*"; log "INFO $*"; }
ok(){ echo "${G}[+]${N} $*"; log "OK   $*"; }
warn(){ echo "${Y}[!]${N} $*"; log "WARN $*"; }
err(){ echo "${R}[x]${N} $*" >&2; log "ERR  $*"; }
die(){ err "$*"; exit 1; }

#------------------------------ banner ----------------------------------------
BANNER=(
'   ██████╗ ██╗     ██╗   ██╗  ██████╗   ██████╗ '
'   ██╔══██╗██║     ██║   ██║ ██╔════╝  ██╔════╝ '
'   ██████╔╝██║     ██║   ██║ ██║  ███╗ ██║  ███╗'
'   ██╔═══╝ ██║     ██║   ██║ ██║   ██║ ██║   ██║'
'   ██║     ███████╗╚██████╔╝ ╚██████╔╝ ╚██████╔╝'
'   ╚═╝     ╚══════╝ ╚═════╝   ╚═════╝   ╚═════╝ '
)
GRAD=(201 171 141 105 75 51)
show_banner(){
  clear 2>/dev/null; echo
  local i; for i in "${!BANNER[@]}"; do printf '\e[1;38;5;%sm%s\e[0m\n' "${GRAD[i]}" "${BANNER[i]}"; done
  printf '   \e[1;38;5;213m⚡ THE WiFi PLUG \e[0m\e[38;5;245m·\e[0m\e[1;38;5;51m share the vibe\e[0m\n'
  printf '   \e[38;5;51m════════════════════════════════════════════\e[0m\n'
  printf '   \e[2;37mcrafted by\e[0m \e[1;38;5;226m@archnexus707\e[0m\n\n'
}
spinner_run(){
  local msg="$1"; shift; ( "$@" ) & local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do printf "\r  ${M}%s${N} %s " "${frames:i++%10:1}" "$msg"; sleep 0.1; done
  wait "$pid"; local rc=$?
  [ $rc -eq 0 ] && printf "\r  ${G}✔${N} %s        \n" "$msg" || printf "\r  ${R}✗${N} %s        \n" "$msg"; return $rc
}

#------------------------------ root & deps -----------------------------------
need_root(){ [ "$(id -u)" -ne 0 ] && { echo "${Y}elevating with sudo...${N}"; exec sudo -E bash "$0" "$@"; }; }

# DEPENDENCY PREFLIGHT — if anything is missing, offer to run setup.sh
preflight(){
  local miss=()
  for t in hostapd dnsmasq iw ip nmcli; do command -v "$t" >/dev/null || miss+=("$t"); done
  command -v nft >/dev/null || command -v iptables >/dev/null || miss+=("nft/iptables")
  if [ ${#miss[@]} -gt 0 ]; then
    show_banner
    warn "missing dependencies: ${W}${miss[*]}${N}"
    if [ -x "$SCRIPT_DIR/setup.sh" ] || [ -f "$SCRIPT_DIR/setup.sh" ]; then
      read -rp "  run ./setup.sh to install them now? [Y/n] " a
      if [[ ! "$a" =~ ^[Nn] ]]; then bash "$SCRIPT_DIR/setup.sh" || die "setup failed"; else die "cannot run without: ${miss[*]}"; fi
    else die "missing ${miss[*]} and no setup.sh found. install: apt install ${miss[*]}"; fi
  fi
  command -v nft >/dev/null && FW=nft || FW=iptables
  HAS_QR=0; command -v qrencode >/dev/null && HAS_QR=1
}
have_whiptail(){ command -v whiptail >/dev/null; }

#------------------------------ iface helpers ---------------------------------
wifi_ifaces(){ local d; for d in /sys/class/net/*/phy80211; do [ -e "$d" ] && basename "$(dirname "$d")"; done 2>/dev/null; }
iface_exists(){ [ -e "/sys/class/net/$1" ]; }
phy_of(){ cat "/sys/class/net/$1/phy80211/name" 2>/dev/null; }
driver_of(){ basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null; }
ip_of(){ ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | head -1; }
ssid_of(){ iw dev "$1" link 2>/dev/null | sed -n 's/^\s*SSID: //p'; }
is_usb_wifi(){ readlink -f "/sys/class/net/$1/device" 2>/dev/null | grep -q usb; }
is_connected(){ iw dev "$1" link 2>/dev/null | grep -q "Connected to"; }
supports_ap(){ local p; p="$(phy_of "$1")"; [ -n "$p" ] && iw phy "$p" info 2>/dev/null | grep -qE '^\s*\*\s*AP\s*$'; }

# DUAL-BAND DETECTION: echoes "2.4", "5", or "2.4/5"
bands_of(){
  local p info b=""; p="$(phy_of "$1")"; [ -z "$p" ] && return
  info="$(iw phy "$p" info 2>/dev/null)"
  echo "$info" | grep -qE ' 24[0-9]{2}(\.[0-9]+)? MHz' && b="2.4"
  echo "$info" | grep -qE ' 5[0-9]{3}(\.[0-9]+)? MHz' && b="${b:+$b/}5"
  echo "${b:-?}"
}
has_5ghz(){ bands_of "$1" | grep -q 5; }

gen_pass(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14; }
detect_country(){ COUNTRY=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z0-9]*\):.*/\1/p' | head -1); [ -z "$COUNTRY" ] || [ "$COUNTRY" = 00 ] && COUNTRY=US; }

save_conf(){ mkdir -p "$(dirname "$CONF_FILE")"; cat >"$CONF_FILE" <<EOF
SSID="$SSID"
PASS="$PASS"
UPSTREAM="$UPSTREAM"
APIFACE="$APIFACE"
SUBNET="$SUBNET"
CHANNEL="$CHANNEL"
BAND="$BAND"
HW="$HW"
WPA_MODE="$WPA_MODE"
ISOLATE="$ISOLATE"
AUTOCHAN="$AUTOCHAN"
WATCHDOG="$WATCHDOG"
MAXSTA="$MAXSTA"
OFFMINS="$OFFMINS"
COUNTRY="$COUNTRY"
EOF
}
load_conf(){ [ -f "$CONF_FILE" ] && . "$CONF_FILE"; }

#===============================================================================
#   PROFILES  (feature 5)
#===============================================================================
save_profile(){
  mkdir -p "$PROFILE_DIR"
  local name="$1"; [ -z "$name" ] && return 1
  name="${name// /_}"
  cp "$CONF_FILE" "$PROFILE_DIR/$name.conf" 2>/dev/null && ok "saved profile: ${G}$name${N}"
}
list_profiles(){ ls "$PROFILE_DIR"/*.conf 2>/dev/null | sed 's#.*/##; s#\.conf$##'; }
load_profile(){
  local name="$1"; [ -f "$PROFILE_DIR/$name.conf" ] || return 1
  cp "$PROFILE_DIR/$name.conf" "$CONF_FILE"; load_conf; ok "loaded profile: ${G}$name${N}"
}
profiles_menu(){
  local ps; mapfile -t ps < <(list_profiles)
  [ ${#ps[@]} -eq 0 ] && { warn "no saved profiles yet"; return 1; }
  if have_whiptail; then
    local args=() p; for p in "${ps[@]}"; do args+=("$p" ""); done
    local sel; sel=$(whiptail --title "Profiles" --menu "load which profile?" 16 50 6 "${args[@]}" 3>&1 1>&2 2>&3) && load_profile "$sel"
  else
    echo "  profiles:"; local i=1; for p in "${ps[@]}"; do echo "   $i) $p"; ((i++)); done
    read -rp "  load #: " n; load_profile "${ps[$((n-1))]}"
  fi
}

#===============================================================================
#   AUTO-DETECT
#===============================================================================
autodetect(){
  detect_country; UPSTREAM=""; APIFACE=""; local dev
  for dev in $(wifi_ifaces); do is_usb_wifi "$dev" && is_connected "$dev" && { UPSTREAM="$dev"; break; }; done
  [ -z "$UPSTREAM" ] && for dev in $(wifi_ifaces); do is_usb_wifi "$dev" && { UPSTREAM="$dev"; break; }; done
  [ -z "$UPSTREAM" ] && for dev in $(wifi_ifaces); do is_connected "$dev" && { UPSTREAM="$dev"; break; }; done
  # prefer a 5GHz-capable AP radio, then ath9k, then any AP-capable
  for dev in $(wifi_ifaces); do [ "$dev" = "$UPSTREAM" ] && continue; supports_ap "$dev" && has_5ghz "$dev" && APIFACE="$dev"; done
  [ -z "$APIFACE" ] && for dev in $(wifi_ifaces); do [ "$dev" = "$UPSTREAM" ] && continue; [ "$(driver_of "$dev")" = ath9k ] && supports_ap "$dev" && APIFACE="$dev"; done
  [ -z "$APIFACE" ] && for dev in $(wifi_ifaces); do [ "$dev" = "$UPSTREAM" ] && continue; supports_ap "$dev" && { APIFACE="$dev"; break; }; done
}

#===============================================================================
#   AUTO-CHANNEL  (feature 2) — scan air, pick least-congested channel
#===============================================================================
best_channel(){
  local dev="$1" band="$2"   # band: bg | a
  local cands scanout
  [ "$band" = a ] && cands="36 40 44 48 149 153 157 161" || cands="1 6 11"
  # need the iface up & idle to scan; it's not claimed yet at this point
  ip link set "$dev" up 2>/dev/null
  scanout="$(timeout 8 iw dev "$dev" scan 2>/dev/null | grep -oE 'DS Parameter set: channel [0-9]+|primary channel: [0-9]+' | grep -oE '[0-9]+$')"
  [ -z "$scanout" ] && { echo ""; return; }   # scan failed -> caller keeps default
  local best="" bestcount=99999 ch cnt
  for ch in $cands; do
    cnt=$(echo "$scanout" | grep -cx "$ch")
    if [ "$cnt" -lt "$bestcount" ]; then bestcount=$cnt; best=$ch; fi
  done
  echo "$best"
}

#===============================================================================
#   QR-CODE JOIN  (feature 1)
#===============================================================================
qr_show(){
  [ "$HAS_QR" = 1 ] || { echo "  ${GR}(install 'qrencode' via ./setup.sh for scannable QR)${N}"; return; }
  local esc="${PASS//\\/\\\\}"; esc="${esc//;/\\;}"; esc="${esc//:/\\:}"; esc="${esc//,/\\,}"
  local auth; [ "$WPA_MODE" = 3 ] && auth=WPA || auth=WPA
  echo "  ${W}scan to join:${N}"
  qrencode -t ANSIUTF8 "WIFI:T:$auth;S:${SSID};P:${esc};;" 2>/dev/null | sed 's/^/  /'
}

#===============================================================================
#   INTERACTIVE SETTINGS
#===============================================================================
ask_hotspot_settings(){
  if have_whiptail; then
    SSID=$(whiptail --title "Hotspot name" --inputbox "Name devices will see (SSID):" 9 60 "$SSID" 3>&1 1>&2 2>&3) || exit 0
    local ch; ch=$(whiptail --title "Password" --menu "WiFi password" 12 60 3 \
      keep "keep: $PASS" random "generate strong one" custom "type my own" 3>&1 1>&2 2>&3)
    case "$ch" in
      random) PASS="$(gen_pass)"; whiptail --title Password --msgbox "Password:\n\n     $PASS\n\n(write it down!)" 11 45;;
      custom) PASS=$(whiptail --passwordbox "Password (>=8 chars):" 9 55 3>&1 1>&2 2>&3);;
    esac
    # band choice, gated by AP radio capability
    local apbands; apbands="$(bands_of "$APIFACE")"
    if echo "$apbands" | grep -q 5; then
      local bnd; bnd=$(whiptail --title "Band" --menu "AP radio ($APIFACE) supports: $apbands GHz" 12 62 2 \
        2.4 "widest range / best thru walls" 5 "faster, shorter range" 3>&1 1>&2 2>&3)
      [ "$bnd" = 5 ] && { BAND=a; HW=a; CHANNEL=36; } || { BAND=bg; HW=g; CHANNEL=6; }
    else
      BAND=bg; HW=g; CHANNEL=6
      whiptail --title "Band" --msgbox "AP radio $APIFACE is 2.4GHz-only.\nUsing 2.4GHz (best range anyway)." 9 50
    fi
    local w; w=$(whiptail --title "Security" --menu "Encryption" 11 60 2 \
      2 "WPA2 (works with everything)" 3 "WPA3/WPA2 (modern)" 3>&1 1>&2 2>&3); WPA_MODE="${w:-2}"
    whiptail --title "Guest isolation" --yesno "Block hotspot users from each other &\nthe office LAN? (recommended)" 9 55 && ISOLATE=yes || ISOLATE=no
    whiptail --title "Auto-channel" --yesno "Auto-pick the least-congested channel\nfor best speed/range?" 9 50 && AUTOCHAN=yes || AUTOCHAN=no
    whiptail --title "Watchdog" --yesno "Auto-reconnect upstream if it drops?\n(keeps the hotspot self-healing)" 9 50 && WATCHDOG=yes || WATCHDOG=no
    MAXSTA=$(whiptail --title "Max devices" --inputbox "Max simultaneous devices (0 = unlimited):" 9 55 "$MAXSTA" 3>&1 1>&2 2>&3) || MAXSTA=0
    OFFMINS=$(whiptail --title "Auto-off timer" --inputbox "Auto shut down after N minutes (0 = never):" 9 55 "$OFFMINS" 3>&1 1>&2 2>&3) || OFFMINS=0
  else
    read -rp "  SSID [$SSID]: " x; SSID="${x:-$SSID}"
    read -rp "  Password ('random'=auto) [$PASS]: " x
    [ "$x" = random ] && { PASS="$(gen_pass)"; echo "   -> $PASS"; } || { [ -n "$x" ] && PASS="$x"; }
    if has_5ghz "$APIFACE"; then read -rp "  Band 2.4/5 [2.4]: " x; [ "$x" = 5 ] && { BAND=a; HW=a; CHANNEL=36; } || { BAND=bg; HW=g; CHANNEL=6; }
    else BAND=bg; HW=g; CHANNEL=6; echo "  (AP radio is 2.4GHz-only)"; fi
    read -rp "  Guest isolation yes/no [$ISOLATE]: " x; ISOLATE="${x:-$ISOLATE}"
    read -rp "  Auto-channel yes/no [$AUTOCHAN]: " x; AUTOCHAN="${x:-$AUTOCHAN}"
    read -rp "  Watchdog yes/no [$WATCHDOG]: " x; WATCHDOG="${x:-$WATCHDOG}"
    read -rp "  Max devices (0=unlimited) [$MAXSTA]: " x; MAXSTA="${x:-$MAXSTA}"
    read -rp "  Auto-off after N minutes (0=never) [$OFFMINS]: " x; OFFMINS="${x:-$OFFMINS}"
  fi
  MAXSTA="${MAXSTA:-0}"; OFFMINS="${OFFMINS:-0}"
  [ ${#PASS} -lt 8 ] && die "Password must be >= 8 characters."
}

print_summary(){
  echo
  echo "  ${M}╔══════════════════ PLUGG CONFIG ══════════════════╗${N}"
  printf "  ${M}║${N}  %-13s ${G}%-33s${N}${M}║${N}\n" "SSID"        "$SSID"
  printf "  ${M}║${N}  %-13s ${G}%-33s${N}${M}║${N}\n" "Password"    "$PASS"
  printf "  ${M}║${N}  %-13s %-33s${M}║${N}\n"          "Security"    "$( [ "$WPA_MODE" = 3 ] && echo 'WPA3/WPA2 mixed' || echo 'WPA2-PSK' )"
  printf "  ${M}║${N}  %-13s ${C}%-33s${N}${M}║${N}\n" "Internet in" "$UPSTREAM → $(ssid_of "$UPSTREAM")"
  printf "  ${M}║${N}  %-13s ${C}%-33s${N}${M}║${N}\n" "Hotspot on"  "$APIFACE ($(driver_of "$APIFACE"), $(bands_of "$APIFACE")G)"
  printf "  ${M}║${N}  %-13s %-33s${M}║${N}\n"          "Band/ch"     "$( [ "$BAND" = a ] && echo 5GHz || echo 2.4GHz ) ch$CHANNEL $( [ "$AUTOCHAN" = yes ] && echo '(auto)' )"
  printf "  ${M}║${N}  %-13s %-33s${M}║${N}\n"          "Isolation"   "$ISOLATE"
  printf "  ${M}║${N}  %-13s %-33s${M}║${N}\n"          "Watchdog"    "$WATCHDOG"
  printf "  ${M}║${N}  %-13s %-33s${M}║${N}\n"          "Max devices" "$( [ "${MAXSTA:-0}" = 0 ] && echo unlimited || echo "$MAXSTA" )"
  printf "  ${M}║${N}  %-13s %-33s${M}║${N}\n"          "Auto-off"    "$( [ "${OFFMINS:-0}" = 0 ] && echo never || echo "${OFFMINS} min" )"
  echo "  ${M}╚══════════════════════════════════════════════════╝${N}"; echo
}

#===============================================================================
#   AUTO FLOW
#===============================================================================
auto_flow(){
  show_banner; info "scanning your radios..."; autodetect
  [ -z "$UPSTREAM" ] && die "No Alfa / connected WiFi found to pull internet from."
  [ -z "$APIFACE" ]  && die "No spare AP-capable radio for the hotspot (need a 2nd card)."
  local up_ssid; up_ssid="$(ssid_of "$UPSTREAM")"
  echo
  echo "  ${W}detected setup${N}"
  echo "  ${GR}├─${N} internet source : ${C}$UPSTREAM${N} $( is_usb_wifi "$UPSTREAM" && echo '(Alfa/USB)') $(bands_of "$UPSTREAM")G → ${G}${up_ssid:-<not connected>}${N}"
  echo "  ${GR}└─${N} hotspot radio   : ${C}$APIFACE${N} ($(driver_of "$APIFACE"), $(bands_of "$APIFACE")G capable)"
  echo
  [ -z "$up_ssid" ] && { warn "Alfa ($UPSTREAM) isn't on any WiFi. Connect it (e.g. HOPE) then rerun."; exit 1; }

  if have_whiptail; then
    whiptail --title "PLUGG · confirm" --yesno "Pull internet from:\n   $up_ssid  (on $UPSTREAM)\nand broadcast a hotspot on $APIFACE ?" 11 62 || exit 0
  else read -rp "  Use '$up_ssid' as internet source? [Y/n] " a; [[ "$a" =~ ^[Nn] ]] && exit 0; fi

  load_conf
  SSID="${SSID:-$DEF_SSID}"; PASS="${PASS:-$DEF_PASS}"; SUBNET="${SUBNET:-$DEF_SUBNET}"
  CHANNEL="${CHANNEL:-$DEF_CHANNEL}"; BAND="${BAND:-$DEF_BAND}"; HW="${HW:-$DEF_HW}"
  WPA_MODE="${WPA_MODE:-$DEF_WPA_MODE}"; ISOLATE="${ISOLATE:-$DEF_ISOLATE}"
  AUTOCHAN="${AUTOCHAN:-$DEF_AUTOCHAN}"; WATCHDOG="${WATCHDOG:-$DEF_WATCHDOG}"
  MAXSTA="${MAXSTA:-$DEF_MAXSTA}"; OFFMINS="${OFFMINS:-$DEF_OFFMINS}"
  ask_hotspot_settings; save_conf
  # offer to remember as a profile
  if have_whiptail && whiptail --title "Profile" --yesno "Save these settings as a named profile\n(so you can reload for '$up_ssid' later)?" 9 55; then
    local pn; pn=$(whiptail --inputbox "profile name:" 8 40 "${up_ssid// /_}" 3>&1 1>&2 2>&3); [ -n "$pn" ] && save_profile "$pn"
  fi
  print_summary
  if have_whiptail; then whiptail --title "go?" --yesno "Fire up the hotspot now?" 8 40 || exit 0
  else read -rp "  Fire it up now? [Y/n] " a; [[ "$a" =~ ^[Nn] ]] && exit 0; fi
  start || die "start failed — see $LOG_FILE"
  live_dashboard
}

#===============================================================================
#   START
#===============================================================================
write_hostapd(){
  local wpa
  if [ "$WPA_MODE" = 3 ]; then wpa="wpa=2
wpa_key_mgmt=WPA-PSK SAE
ieee80211w=1
sae_password=$PASS"
  else wpa="wpa=2
wpa_key_mgmt=WPA-PSK"; fi
  { echo "interface=$APIFACE"; echo "driver=nl80211"; echo "country_code=$COUNTRY"; echo "ieee80211d=1"
    echo "ssid=$SSID"; echo "hw_mode=$HW"; echo "channel=$CHANNEL"
    if [ "$HW" = g ]; then echo "ieee80211n=1"; echo "wmm_enabled=1"; echo "ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]"
    else echo "ieee80211n=1"; echo "ieee80211ac=1"; echo "wmm_enabled=1"; echo "ht_capab=[HT40+]"; echo "vht_oper_chwidth=1"; fi
    echo "auth_algs=1"; echo "ignore_broadcast_ssid=0"; echo "wpa_passphrase=$PASS"; echo "rsn_pairwise=CCMP"; echo "$wpa"
    [ "$ISOLATE" = yes ] && echo "ap_isolate=1"
    # control socket (for live kick/ban) + MAC deny-list
    echo "ctrl_interface=$HOSTAPD_CTL"; echo "ctrl_interface_group=0"
    echo "macaddr_acl=0"; echo "deny_mac_file=$DENY_FILE"
    [ "${MAXSTA:-0}" != 0 ] && echo "max_num_sta=$MAXSTA"; } >"$HOSTAPD_CONF"
  touch "$DENY_FILE"
}
write_dnsmasq(){ cat >"$DNSMASQ_CONF" <<EOF
interface=$APIFACE
bind-interfaces
except-interface=lo
dhcp-range=$SUBNET.10,$SUBNET.250,255.255.255.0,12h
dhcp-option=option:router,$SUBNET.1
dhcp-option=option:dns-server,$SUBNET.1
server=1.1.1.1
server=8.8.8.8
domain-needed
bogus-priv
no-resolv
dhcp-leasefile=$LEASE_FILE
log-facility=$RUN_DIR/dnsmasq_log
EOF
}
upstream_gw(){ ip route show default 2>/dev/null | awk -v u="$UPSTREAM" '$0 ~ ("dev "u){print $3; exit}'; }
upstream_online(){ ping -c1 -W2 -I "$UPSTREAM" 1.1.1.1 >/dev/null 2>&1; }

setup_routing(){
  local sub="$SUBNET.0/24"
  ip rule del from "$sub" lookup "$RT_TABLE" 2>/dev/null
  ip rule add from "$sub" lookup "$RT_TABLE" priority 200 2>/dev/null
  ip route flush table "$RT_TABLE" 2>/dev/null
  ip route replace "$sub" dev "$APIFACE" table "$RT_TABLE" 2>/dev/null
  assert_routing
}

# Keeps the "prefer upstream, fall back to system default" policy correct over time.
# The kernel wipes routes via an iface whenever it flaps, so this re-asserts them;
# and if the upstream loses internet it drops the table-200 default so clients fail
# over to the wired/other default route instead of black-holing.
assert_routing(){
  local sub="$SUBNET.0/24" gw
  ip rule show | grep -q "from $sub lookup $RT_TABLE" || ip rule add from "$sub" lookup "$RT_TABLE" priority 200 2>/dev/null
  ip route replace "$sub" dev "$APIFACE" table "$RT_TABLE" 2>/dev/null
  if upstream_online; then
    gw="$(upstream_gw)"
    [ -n "$gw" ] && ip route replace default via "$gw" dev "$UPSTREAM" table "$RT_TABLE" 2>/dev/null
  else
    ip route del default table "$RT_TABLE" 2>/dev/null   # -> clients use system default (e.g. eth0)
  fi
  ip route flush cache 2>/dev/null
}
teardown_routing(){ local sub="$SUBNET.0/24"; [ -z "$SUBNET" ] && return
  ip rule del from "$sub" lookup "$RT_TABLE" 2>/dev/null; ip route flush table "$RT_TABLE" 2>/dev/null; ip route flush cache 2>/dev/null; }
setup_firewall(){
  local sub="$SUBNET.0/24"; echo 1 >/proc/sys/net/ipv4/ip_forward
  if [ "$FW" = nft ]; then
    nft delete table ip $NFT_TABLE 2>/dev/null
    # NOTE: chain names must avoid nft keywords (e.g. 'fwd' is reserved), and every
    # statement + closing brace must be on its own line, or nft rejects the ruleset.
    # Resilience: masquerade/allow out ANY uplink except the AP itself, so clients keep
    # internet even when the preferred upstream drops and traffic fails over (e.g. to eth0).
    # Isolation blocks guests from private LANs by DESTINATION (survives failover) while
    # public internet still flows.
    local isolate_rule=""
    [ "$ISOLATE" = yes ] && isolate_rule="ip saddr $sub ip daddr { 192.168.0.0/16, 172.16.0.0/12 } counter drop"
    nft -f - <<EOF
table ip $NFT_TABLE {
	chain postnat {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr $sub oifname != "$APIFACE" counter masquerade
	}
	chain filt {
		type filter hook forward priority filter; policy accept;
		ip daddr $sub ct state established,related counter accept
		$isolate_rule
		ip saddr $sub oifname != "$APIFACE" counter accept
	}
}
EOF
    local rc=$?
    if [ $rc -ne 0 ]; then err "nft ruleset failed to load — NAT not active"; return 1; fi
  else
    iptables -t nat -A POSTROUTING -s "$sub" ! -o "$APIFACE" -j MASQUERADE -m comment --comment "$NFT_TABLE"
    iptables -A FORWARD -d "$sub" -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$NFT_TABLE"
    [ "$ISOLATE" = yes ] && { iptables -A FORWARD -s "$sub" -d 192.168.0.0/16 -j DROP -m comment --comment "$NFT_TABLE"
      iptables -A FORWARD -s "$sub" -d 172.16.0.0/12 -j DROP -m comment --comment "$NFT_TABLE"; }
    iptables -A FORWARD -s "$sub" ! -o "$APIFACE" -j ACCEPT -m comment --comment "$NFT_TABLE"
  fi
  return 0
}
teardown_firewall(){
  if [ "$FW" = nft ]; then nft delete table ip $NFT_TABLE 2>/dev/null
  else iptables-save 2>/dev/null | grep -v "$NFT_TABLE" | iptables-restore 2>/dev/null; fi
  echo 0 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
}

# WATCHDOG (feature 3) — background self-heal of the upstream link
start_watchdog(){
  # Even if the user disabled the watchdog, we still must maintain failover routing,
  # because the kernel wipes table-200 routes whenever the upstream iface flaps.
  ( while true; do
      if [ "$WATCHDOG" = yes ] && ! upstream_online; then
        log "WATCHDOG $UPSTREAM lost internet — reconnecting + failing over"
        nmcli device connect "$UPSTREAM" >/dev/null 2>&1
      fi
      assert_routing        # re-assert / fail over to system default when upstream is down
      sleep 12
    done ) & echo $! >"$WATCHDOG_PID"
}
stop_watchdog(){ [ -f "$WATCHDOG_PID" ] && { kill "$(cat "$WATCHDOG_PID")" 2>/dev/null; rm -f "$WATCHDOG_PID"; }; }

# AUTO-OFF TIMER (feature 7) — shut down + reset after OFFMINS minutes
start_autooff(){
  [ "${OFFMINS:-0}" -gt 0 ] 2>/dev/null || return
  local secs=$((OFFMINS*60))
  echo $(( $(date +%s) + secs )) >"$RUN_DIR/autooff.at"
  # tears down cleanly in BOTH cli & web modes (fresh process runs stop())
  ( sleep "$secs"; log "AUTO-OFF timer ($OFFMINS min) elapsed — stopping"; PLUGG_HEADLESS=0 bash "$0" stop >/dev/null 2>&1 ) &
  echo $! >"$AUTOOFF_PID"
  ok "auto-off armed: hotspot ends in ${OFFMINS} min"
}
stop_autooff(){ [ -f "$AUTOOFF_PID" ] && { kill "$(cat "$AUTOOFF_PID")" 2>/dev/null; rm -f "$AUTOOFF_PID"; }; }

# KICK + BAN (feature 6) — deauth a station and add it to the deny-list, live
hapd_cli(){ hostapd_cli -p "$HOSTAPD_CTL" -i "$APIFACE" "$@" 2>/dev/null; }
ban_mac(){
  local mac="$1"; [ -z "$mac" ] && return 1
  [ -z "$APIFACE" ] && load_conf
  grep -qi "$mac" "$DENY_FILE" 2>/dev/null || echo "$mac" >>"$DENY_FILE"
  hapd_cli deny_acl ADD_MAC "$mac" >/dev/null
  hapd_cli deauthenticate "$mac" >/dev/null
}
kick_device(){
  is_running || { warn "hotspot not running"; return 1; }
  local macs; mapfile -t macs < <(iw dev "$APIFACE" station dump 2>/dev/null | awk '/Station/{print $2}')
  [ ${#macs[@]} -eq 0 ] && { warn "no devices connected"; return 1; }
  local mac
  if have_whiptail; then
    local args=() m nm
    for m in "${macs[@]}"; do nm=$(awk -v M="$m" '$2==M{print $4}' "$LEASE_FILE" 2>/dev/null); args+=("$m" "${nm:-device}"); done
    mac=$(whiptail --title "Kick + ban device" --menu "pick a device to boot & block:" 16 55 6 "${args[@]}" 3>&1 1>&2 2>&3) || return
  else
    echo "  connected:"; local i=1; for m in "${macs[@]}"; do echo "   $i) $m"; ((i++)); done
    read -rp "  kick #: " n; mac="${macs[$((n-1))]}"
  fi
  [ -z "$mac" ] && return
  ban_mac "$mac"
  ok "kicked + banned ${R}$mac${N} (won't reconnect)"
}
unban_all(){ : >"$DENY_FILE"; hapd_cli deny_acl CLEAR >/dev/null; ok "cleared the ban-list"; }

is_hostapd_up(){ [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; }
is_dnsmasq_up(){ [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; }
is_running(){ is_hostapd_up; }

start(){
  [ -z "$APIFACE" ] && load_conf
  [ -z "$APIFACE" ] && die "not configured — run AUTO first"
  mkdir -p "$RUN_DIR"; detect_country
  is_running && { warn "already running"; return 0; }
  echo
  { echo "APIFACE=$APIFACE"; echo "UPSTREAM=$UPSTREAM"; echo "SUBNET=$SUBNET"; echo "WATCHDOG=$WATCHDOG"
    echo "NM_MANAGED=$(nmcli -g GENERAL.NM-MANAGED device show "$APIFACE" 2>/dev/null)"; } >"$STATE_FILE"

  # auto-channel BEFORE claiming the radio (needs it scannable)
  if [ "$AUTOCHAN" = yes ]; then
    local bc; bc="$(best_channel "$APIFACE" "$BAND")"
    if [ -n "$bc" ]; then CHANNEL="$bc"; ok "auto-channel picked ch$CHANNEL (least congested)"; else warn "auto-channel scan failed — using ch$CHANNEL"; fi
  fi

  spinner_run "claiming radio $APIFACE from NetworkManager" bash -c "
    nmcli device disconnect '$APIFACE' >/dev/null 2>&1
    nmcli device set '$APIFACE' managed no >/dev/null 2>&1
    rfkill unblock wifi 2>/dev/null
    ip link set '$APIFACE' down 2>/dev/null; ip addr flush dev '$APIFACE' 2>/dev/null
    ip link set '$APIFACE' up; ip addr add '$SUBNET.1/24' dev '$APIFACE'"
  STARTED_SESSION=1
  write_hostapd; write_dnsmasq
  spinner_run "policy routing via $UPSTREAM" setup_routing
  spinner_run "NAT / firewall"              setup_firewall
  spinner_run "starting hostapd (the AP)"   bash -c "hostapd -B -P '$HOSTAPD_PID' '$HOSTAPD_CONF' >>'$LOG_FILE' 2>&1"
  sleep 2
  is_hostapd_up || { err "hostapd failed:"; tail -n 12 "$LOG_FILE"; return 1; }
  pkill -F "$DNSMASQ_PID" 2>/dev/null
  spinner_run "starting dnsmasq (DHCP+DNS)" bash -c "dnsmasq --conf-file='$DNSMASQ_CONF' --pid-file='$DNSMASQ_PID' >>'$LOG_FILE' 2>&1"
  sleep 1
  start_watchdog
  start_autooff
  echo; ok "${W}PLUGG IS LIVE — the vibe is shared${N}"
  echo "     ${GR}connect to${N} ${G}$SSID${N}   ${GR}password${N} ${G}$PASS${N}"
  echo "     ${GR}internet via${N} ${C}$UPSTREAM → $(ssid_of "$UPSTREAM")${N}"; echo
  qr_show; echo
}

#===============================================================================
#   STOP / CLEANUP  (EXIT trap)
#===============================================================================
stop(){
  [ "$CLEANED" = 1 ] && return
  [ -f "$STATE_FILE" ] && . "$STATE_FILE"; [ -z "$SUBNET" ] && load_conf
  info "resetting everything back to normal..."
  stop_watchdog; stop_autooff
  [ -f "$DNSMASQ_PID" ] && { pkill -F "$DNSMASQ_PID" 2>/dev/null; rm -f "$DNSMASQ_PID"; }
  [ -f "$HOSTAPD_PID" ] && { pkill -F "$HOSTAPD_PID" 2>/dev/null; rm -f "$HOSTAPD_PID"; }
  pkill -f "hostapd .*$RUN_DIR" 2>/dev/null
  teardown_firewall; teardown_routing
  local ap="$APIFACE"
  if [ -n "$ap" ] && iface_exists "$ap"; then
    ip addr flush dev "$ap" 2>/dev/null; ip link set "$ap" down 2>/dev/null
    nmcli device set "$ap" managed yes >/dev/null 2>&1; ip link set "$ap" up 2>/dev/null
    nmcli device connect "$ap" >/dev/null 2>&1 &
  fi
  rm -f "$STATE_FILE"; CLEANED=1
  ok "clean. routing, firewall & $ap restored to NetworkManager."
}
# in headless/web mode the process exits right after 'up' — do NOT tear down then
cleanup_on_exit(){ [ "${PLUGG_HEADLESS:-0}" = 1 ] && return; [ "$STARTED_SESSION" = 1 ] && [ "$CLEANED" = 0 ] && { echo; stop; }; }
trap cleanup_on_exit EXIT
trap 'echo; warn "signal caught — shutting down PLUGG"; exit 130' INT TERM HUP

#===============================================================================
#   STATUS / DASHBOARD  (feature 4: live bandwidth)
#===============================================================================
human_rate(){ awk -v b="${1:-0}" 'BEGIN{ if(b>=1048576) printf "%.1f MB/s", b/1048576; else if(b>=1024) printf "%.0f KB/s", b/1024; else printf "%d B/s", b }'; }
render_status(){
  load_conf
  local rx tx now drx dtx dt up_ok
  rx=$(cat "/sys/class/net/$APIFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/$APIFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "$PREV_T" -gt 0 ]; then dt=$((now-PREV_T)); [ "$dt" -lt 1 ] && dt=1
    drx=$(( (rx-PREV_RX)/dt )); dtx=$(( (tx-PREV_TX)/dt )); else drx=0; dtx=0; fi
  PREV_RX=$rx; PREV_TX=$tx; PREV_T=$now
  ping -c1 -W1 -I "$UPSTREAM" 1.1.1.1 >/dev/null 2>&1 && up_ok="${G}online${N}" || up_ok="${R}OFFLINE${N}"

  echo "  ${W}state${N}   : $( is_running && echo "${G}LIVE${N}" || echo "${R}stopped${N}" )   ${GR}hostapd $( is_hostapd_up && echo up || echo down ) · dnsmasq $( is_dnsmasq_up && echo up || echo down ) · watchdog $( [ -f "$WATCHDOG_PID" ] && echo on || echo off )${N}"
  echo "  ${W}ssid${N}    : ${G}$SSID${N}   ${GR}pass${N} ${G}$PASS${N}"
  echo "  ${W}uplink${N}  : ${C}$UPSTREAM${N} → $(ssid_of "$UPSTREAM")  [$up_ok]"
  echo "  ${W}traffic${N} : ${C}▼ $(human_rate ${drx:-0})${N}   ${M}▲ $(human_rate ${dtx:-0})${N}   ${GR}(hotspot radio)${N}"
  if [ -f "$RUN_DIR/autooff.at" ]; then
    local rem=$(( $(cat "$RUN_DIR/autooff.at") - $(date +%s) )); [ "$rem" -lt 0 ] && rem=0
    printf "  ${W}auto-off${N}: ${O}%dh %02dm %02ds remaining${N}\n" $((rem/3600)) $(((rem%3600)/60)) $((rem%60))
  fi
  local banned; banned=$(grep -c . "$DENY_FILE" 2>/dev/null); [ "${banned:-0}" -gt 0 ] && echo "  ${W}banned${N}  : ${R}$banned device(s) blocked${N}"
  echo
  echo "  ${W}connected devices${N}"
  if [ -f "$LEASE_FILE" ] && [ -s "$LEASE_FILE" ]; then
    printf "    ${GR}%-15s %-18s %-14s %s${N}\n" "IP" "MAC" "NAME" "SIGNAL"
    while read -r _ mac ipa name _; do
      local sig; sig=$(iw dev "$APIFACE" station get "$mac" 2>/dev/null | sed -n 's/.*signal:\s*\(-[0-9]*\).*/\1 dBm/p' | head -1)
      printf "    %-15s %-18s %-14s %s\n" "$ipa" "$mac" "${name/\*/-}" "${sig:-–}"
    done <"$LEASE_FILE"
    echo "    ${GR}total: $(wc -l <"$LEASE_FILE") device(s)${N}"
  else echo "    ${GR}(waiting for devices to join...)${N}"; fi
}
status(){ show_banner; render_status; echo; qr_show; }

live_dashboard(){
  DASH_STOP=0; PREV_T=0; trap 'DASH_STOP=1' INT
  while [ "$DASH_STOP" = 0 ]; do
    show_banner; render_status
    echo; echo "  ${M}▸ Ctrl-C to STOP the hotspot and reset everything${N}"
    sleep 3
  done
  trap 'echo; warn "signal caught — shutting down PLUGG"; exit 130' INT TERM HUP
  echo; info "stopping on your request..."; stop; exit 0
}

#===============================================================================
#   MENU
#===============================================================================
menu(){
  while true; do
    if have_whiptail; then
      local st; is_running && st="LIVE" || st="off"
      local ch; ch=$(whiptail --title "PLUGG · @archnexus707 · [$st]" --menu "the wifi plug — pick a move:" 20 60 10 \
        A "⚡ AUTO — detect + run everything" \
        S "▶  Start (saved config)" \
        X "■  Stop + reset now" \
        I "ℹ  Status / devices / QR" \
        M "▤  Live dashboard" \
        K "🚫 Kick + ban a device" \
        U "♻  Clear ban-list" \
        P "💾 Load a profile" \
        C "⚙  Configure manually" \
        L "▦  View log" \
        Q "✕  Quit" 3>&1 1>&2 2>&3) || break
    else show_banner; echo "  ${W}A${N}uto ${W}S${N}tart ${W}X${N}stop ${W}I${N}nfo ${W}M${N}onitor ${W}K${N}ick ${W}U${N}nban ${W}P${N}rofiles ${W}C${N}onfig ${W}L${N}og ${W}Q${N}uit"; read -rp "  > " ch; fi
    case "${ch^^}" in
      A) auto_flow ;;
      S) start; read -rp "  enter..." _ ;;
      X) STARTED_SESSION=1; stop; read -rp "  enter..." _ ;;
      I) status; read -rp "  enter..." _ ;;
      M) live_dashboard ;;
      K) kick_device; read -rp "  enter..." _ ;;
      U) unban_all; read -rp "  enter..." _ ;;
      P) profiles_menu; read -rp "  enter..." _ ;;
      C) autodetect; load_conf
         SSID="${SSID:-$DEF_SSID}"; PASS="${PASS:-$DEF_PASS}"; SUBNET="${SUBNET:-$DEF_SUBNET}"
         CHANNEL="${CHANNEL:-$DEF_CHANNEL}"; BAND="${BAND:-$DEF_BAND}"; HW="${HW:-$DEF_HW}"
         WPA_MODE="${WPA_MODE:-$DEF_WPA_MODE}"; ISOLATE="${ISOLATE:-$DEF_ISOLATE}"
         AUTOCHAN="${AUTOCHAN:-$DEF_AUTOCHAN}"; WATCHDOG="${WATCHDOG:-$DEF_WATCHDOG}"
         MAXSTA="${MAXSTA:-$DEF_MAXSTA}"; OFFMINS="${OFFMINS:-$DEF_OFFMINS}"
         ask_hotspot_settings; save_conf
         have_whiptail && whiptail --yesno "save as a named profile?" 8 40 && { pn=$(whiptail --inputbox "name:" 8 40 3>&1 1>&2 2>&3); [ -n "$pn" ] && save_profile "$pn"; }
         print_summary; read -rp "  enter..." _ ;;
      L) tail -n 40 "$LOG_FILE" 2>/dev/null; read -rp "  enter..." _ ;;
      Q) break ;;
    esac
  done
}

#===============================================================================
#   HEADLESS JSON API  (consumed by the web UI — single source of truth)
#===============================================================================
json_esc(){ local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; printf '%s' "$s"; }

emit_detect_json(){
  autodetect
  local u_on; ping -c1 -W1 -I "$UPSTREAM" 1.1.1.1 >/dev/null 2>&1 && u_on=true || u_on=false
  printf '{"upstream":{"iface":"%s","ssid":"%s","bands":"%s","driver":"%s","usb":%s,"online":%s},"ap":{"iface":"%s","bands":"%s","driver":"%s","has5":%s}}\n' \
    "$(json_esc "$UPSTREAM")" "$(json_esc "$(ssid_of "$UPSTREAM")")" "$(bands_of "$UPSTREAM")" "$(json_esc "$(driver_of "$UPSTREAM")")" \
    "$(is_usb_wifi "$UPSTREAM" && echo true || echo false)" "$u_on" \
    "$(json_esc "$APIFACE")" "$(bands_of "$APIFACE")" "$(json_esc "$(driver_of "$APIFACE")")" \
    "$(has_5ghz "$APIFACE" && echo true || echo false)"
}

emit_status_json(){
  load_conf
  local running; is_running && running=true || running=false
  local rx tx; rx=$(cat "/sys/class/net/$APIFACE/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx=$(cat "/sys/class/net/$APIFACE/statistics/tx_bytes" 2>/dev/null || echo 0)
  local online; ping -c1 -W1 -I "$UPSTREAM" 1.1.1.1 >/dev/null 2>&1 && online=true || online=false
  local off_at=0; [ -f "$RUN_DIR/autooff.at" ] && off_at=$(cat "$RUN_DIR/autooff.at")
  local banned; banned=$(grep -c . "$DENY_FILE" 2>/dev/null); banned=${banned:-0}
  local clients="" first=1 mac ipa name sig item
  if [ -f "$LEASE_FILE" ]; then
    while read -r _ mac ipa name _; do
      [ -z "$mac" ] && continue
      sig=$(iw dev "$APIFACE" station get "$mac" 2>/dev/null | sed -n 's/.*signal:\s*\(-\?[0-9]*\).*/\1/p' | head -1)
      item=$(printf '{"ip":"%s","mac":"%s","name":"%s","signal":"%s"}' "$(json_esc "$ipa")" "$(json_esc "$mac")" "$(json_esc "${name/\*/-}")" "${sig:-}")
      [ $first -eq 1 ] && { clients="$item"; first=0; } || clients="$clients,$item"
    done <"$LEASE_FILE"
  fi
  printf '{"running":%s,"ssid":"%s","pass":"%s","upstream":"%s","upstream_ssid":"%s","apiface":"%s","subnet":"%s","online":%s,"rx":%s,"tx":%s,"off_at":%s,"banned":%s,"maxsta":%s,"isolate":"%s","watchdog":"%s","autochan":"%s","offmins":"%s","band":"%s","channel":"%s","clients":[%s]}\n' \
    "$running" "$(json_esc "$SSID")" "$(json_esc "$PASS")" "$(json_esc "$UPSTREAM")" "$(json_esc "$(ssid_of "$UPSTREAM")")" \
    "$(json_esc "$APIFACE")" "$(json_esc "$SUBNET")" "$online" "$rx" "$tx" "$off_at" "$banned" "${MAXSTA:-0}" \
    "$(json_esc "$ISOLATE")" "$(json_esc "$WATCHDOG")" "$(json_esc "${AUTOCHAN:-yes}")" "$(json_esc "${OFFMINS:-0}")" "$(json_esc "$BAND")" "$(json_esc "$CHANNEL")" "$clients"
}

emit_profiles_json(){
  local p first=1 out=""
  for p in $(list_profiles); do [ $first -eq 1 ] && { out="\"$(json_esc "$p")\""; first=0; } || out="$out,\"$(json_esc "$p")\""; done
  printf '[%s]\n' "$out"
}

#===============================================================================
#   ENTRY
#===============================================================================
mkdir -p "$RUN_DIR" "$PROFILE_DIR" 2>/dev/null; touch "$LOG_FILE" 2>/dev/null
need_root "$@"
# headless API calls must not run the interactive preflight/banner
case "${1:-}" in status-json|detect-json|profiles-json|up|down|kick|unban|apply-profile) HEADLESS_CMD=1;; *) HEADLESS_CMD=0;; esac
if [ "$HEADLESS_CMD" = 0 ]; then
  preflight
else
  command -v nft >/dev/null && FW=nft || FW=iptables
  command -v qrencode >/dev/null && HAS_QR=1 || HAS_QR=0
fi
detect_country
case "${1:-menu}" in
  auto)    auto_flow ;;
  start)   [ -f "$CONF_FILE" ] || autodetect; start; live_dashboard ;;
  stop|down) STARTED_SESSION=1; stop ;;
  status)  status ;;
  config|configure) autodetect; load_conf; ask_hotspot_settings; save_conf; print_summary ;;
  profile) load_profile "$2" && { start; live_dashboard; } ;;
  # ---- headless API (web UI) ----
  up)          start ;;                       # PLUGG_HEADLESS=1 keeps it alive after exit
  status-json) emit_status_json ;;
  detect-json) emit_detect_json ;;
  profiles-json) emit_profiles_json ;;
  apply-profile) load_profile "$2" >/dev/null 2>&1 && echo '{"ok":true}' || echo '{"ok":false}' ;;
  kick)        ban_mac "$2" && echo '{"ok":true}' || echo '{"ok":false}' ;;
  unban)       unban_all >/dev/null 2>&1; echo '{"ok":true}' ;;
  menu|"") menu ;;
  *) echo "usage: $0 [auto|start|stop|status|config|profile <name>|menu]"; exit 1 ;;
esac
