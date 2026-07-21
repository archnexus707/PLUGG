#!/usr/bin/env bash
#===============================================================================
#   PLUGG · webui.sh  —  launch the browser UI                by @archnexus707
#   Runs the Flask backend (as root), prints the phone URL, opens your
#   browser, and tears the hotspot back down when you stop the server.
#===============================================================================
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PLUGG_PORT:-8088}"

if [ -t 1 ]; then G=$'\e[38;5;46m'; C=$'\e[38;5;51m'; Y=$'\e[38;5;226m'; M=$'\e[38;5;201m'; R=$'\e[38;5;196m'; W=$'\e[1m'; N=$'\e[0m'
else G=; C=; Y=; M=; R=; W=; N=; fi

banner(){ clear 2>/dev/null; echo
  local L=('   ██████╗ ██╗     ██╗   ██╗  ██████╗   ██████╗ ' '   ██╔══██╗██║     ██║   ██║ ██╔════╝  ██╔════╝ '
'   ██████╔╝██║     ██║   ██║ ██║  ███╗ ██║  ███╗' '   ██╔═══╝ ██║     ██║   ██║ ██║   ██║ ██║   ██║'
'   ██║     ███████╗╚██████╔╝ ╚██████╔╝ ╚██████╔╝' '   ╚═╝     ╚══════╝ ╚═════╝   ╚═════╝   ╚═════╝ ')
  local col=(201 171 141 105 75 51) i; for i in "${!L[@]}"; do printf '\e[1;38;5;%sm%s\e[0m\n' "${col[i]}" "${L[i]}"; done
  printf '   \e[1;38;5;213m🌐 web control panel\e[0m  \e[2;37mby\e[0m \e[1;38;5;226m@archnexus707\e[0m\n'
  printf '   \e[38;5;51m════════════════════════════════════════════\e[0m\n\n'; }

banner
# --- root ---
[ "$(id -u)" -ne 0 ] && { echo "${Y}elevating with sudo...${N}"; exec sudo -E bash "$0" "$@"; }

# --- python + flask ---
command -v python3 >/dev/null || { echo "${R}python3 not found — run ./setup.sh${N}"; exit 1; }
if ! python3 -c 'import flask' 2>/dev/null; then
  echo "${Y}Flask not installed.${N}"
  read -rp "  install it now (apt install python3-flask)? [Y/n] " a
  if [[ ! "$a" =~ ^[Nn] ]]; then
    apt-get install -y python3-flask 2>/dev/null || pip3 install --break-system-packages flask 2>/dev/null || { echo "${R}install failed${N}"; exit 1; }
  else exit 1; fi
fi
chmod +x "$SCRIPT_DIR/launcher.sh" 2>/dev/null

export PLUGG_PORT="$PORT"

# --- figure out the reachable addresses ---
AP_IP="$(ip -4 -o addr show 2>/dev/null | awk '/10\.42\.0\.1\//{print $4}' | cut -d/ -f1 | head -1)"
LAN_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^10\.42\.' | head -1)"

echo "  ${W}web UI starting…${N}   ${G}(open access)${N}"
echo "  ${G}▸ on THIS laptop :${N} ${C}http://127.0.0.1:$PORT${N}"
[ -n "$AP_IP" ]  && echo "  ${G}▸ from a phone   :${N} ${C}http://$AP_IP:$PORT${N}"
[ -n "$LAN_IP" ] && echo "  ${G}▸ from the LAN   :${N} ${C}http://$LAN_IP:$PORT${N}"
echo "  ${M}Ctrl-C to stop the server AND reset the hotspot.${N}"; echo

# --- guarantee teardown when the server exits ---
cleanup(){ echo; echo "${Y}stopping server & resetting hotspot…${N}"; PLUGG_HEADLESS=0 bash "$SCRIPT_DIR/launcher.sh" stop >/dev/null 2>&1; echo "${G}done.${N}"; }
trap cleanup EXIT INT TERM

# --- open a browser (best-effort) ---
( sleep 1; command -v xdg-open >/dev/null && xdg-open "http://127.0.0.1:$PORT" >/dev/null 2>&1 ) &

# --- run the backend (foreground) ---
python3 "$SCRIPT_DIR/plugg_web.py"
