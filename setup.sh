#!/usr/bin/env bash
#===============================================================================
#   PLUGG · setup.sh  —  dependency bootstrapper           by @archnexus707
#   Detects your package manager, installs everything launcher.sh needs,
#   and makes the tool ready to run. Run this ONCE (or whenever deps change).
#===============================================================================
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then R=$'\e[38;5;196m'; G=$'\e[38;5;46m'; Y=$'\e[38;5;226m'; C=$'\e[38;5;51m'; M=$'\e[38;5;201m'; W=$'\e[1m'; N=$'\e[0m'
else R=; G=; Y=; C=; M=; W=; N=; fi

banner() {
  clear 2>/dev/null; echo
  local L=(
'   ██████╗ ██╗     ██╗   ██╗  ██████╗   ██████╗ '
'   ██╔══██╗██║     ██║   ██║ ██╔════╝  ██╔════╝ '
'   ██████╔╝██║     ██║   ██║ ██║  ███╗ ██║  ███╗'
'   ██╔═══╝ ██║     ██║   ██║ ██║   ██║ ██║   ██║'
'   ██║     ███████╗╚██████╔╝ ╚██████╔╝ ╚██████╔╝'
'   ╚═╝     ╚══════╝ ╚═════╝   ╚═════╝   ╚═════╝ ')
  local col=(201 171 141 105 75 51) i
  for i in "${!L[@]}"; do printf '\e[1;38;5;%sm%s\e[0m\n' "${col[i]}" "${L[i]}"; done
  printf '   \e[1;38;5;213m⚙ setup / dependency bootstrapper\e[0m  \e[2;37mby\e[0m \e[1;38;5;226m@archnexus707\e[0m\n'
  printf '   \e[38;5;51m════════════════════════════════════════════\e[0m\n\n'
}
info(){ echo "${C}[*]${N} $*"; } ; ok(){ echo "${G}[+]${N} $*"; } ; warn(){ echo "${Y}[!]${N} $*"; } ; err(){ echo "${R}[x]${N} $*" >&2; }

banner

# --- must be root to install ---
if [ "$(id -u)" -ne 0 ]; then warn "need root to install packages — re-running with sudo"; exec sudo -E bash "$0" "$@"; fi

# --- detect package manager ---
if   command -v apt-get >/dev/null; then PM="apt";    INSTALL="apt-get install -y";        UPDATE="apt-get update"
elif command -v dnf     >/dev/null; then PM="dnf";    INSTALL="dnf install -y";            UPDATE=":"
elif command -v pacman  >/dev/null; then PM="pacman"; INSTALL="pacman -S --noconfirm";     UPDATE="pacman -Sy"
elif command -v zypper  >/dev/null; then PM="zypper"; INSTALL="zypper install -y";         UPDATE=":"
else err "no supported package manager found (apt/dnf/pacman/zypper)"; exit 1; fi
ok "package manager: ${W}$PM${N}"

# --- binary -> package name map (per manager where it differs) ---
# format: "binary:apt_pkg:dnf_pkg:pacman_pkg"
REQ=(
  "hostapd:hostapd:hostapd:hostapd"
  "dnsmasq:dnsmasq:dnsmasq:dnsmasq"
  "iw:iw:iw:iw"
  "ip:iproute2:iproute:iproute2"
  "nft:nftables:nftables:nftables"
  "rfkill:rfkill:rfkill:rfkill-utils"
  "nmcli:network-manager:NetworkManager:networkmanager"
  "whiptail:whiptail:newt:libnewt"
)
# optional but powering the cool features
OPT=(
  "qrencode:qrencode:qrencode:qrencode"                       # QR-code join (CLI + web)
  "python3:python3:python3:python"                            # web UI backend
  "flask:python3-flask:python3-flask:python-flask"            # web UI (Flask) — checked specially below
)

pkg_for() { # $1=index-string $2=manager
  local s="$1"; IFS=':' read -r bin apt dnf pac <<<"$s"
  case "$2" in apt) echo "$apt";; dnf) echo "$dnf";; pacman) echo "$pac";; *) echo "$apt";; esac
}

missing_bins=(); missing_pkgs=()
info "checking required dependencies..."
for e in "${REQ[@]}"; do
  bin="${e%%:*}"
  if command -v "$bin" >/dev/null; then printf "   ${G}✔${N} %-10s\n" "$bin"
  else printf "   ${R}✗${N} %-10s ${Y}(missing)${N}\n" "$bin"; missing_bins+=("$bin"); missing_pkgs+=("$(pkg_for "$e" "$PM")"); fi
done
echo
info "checking optional (feature) dependencies..."
opt_missing_pkgs=()
for e in "${OPT[@]}"; do
  bin="${e%%:*}"; present=0
  if [ "$bin" = flask ]; then python3 -c 'import flask' 2>/dev/null && present=1
  elif command -v "$bin" >/dev/null; then present=1; fi
  if [ "$present" = 1 ]; then printf "   ${G}✔${N} %-10s\n" "$bin"
  else printf "   ${Y}○${N} %-10s ${Y}(optional — web UI / QR)${N}\n" "$bin"; opt_missing_pkgs+=("$(pkg_for "$e" "$PM")"); fi
done
echo

TO_INSTALL=("${missing_pkgs[@]}" "${opt_missing_pkgs[@]}")
if [ ${#TO_INSTALL[@]} -eq 0 ]; then
  ok "all dependencies already present — you're good to go."
else
  info "will install: ${W}${TO_INSTALL[*]}${N}"
  read -rp "   proceed? [Y/n] " a; [[ "$a" =~ ^[Nn] ]] && { warn "skipped install"; exit 0; }
  info "updating package lists..."; $UPDATE >/dev/null 2>&1 || warn "update failed (continuing)"
  if $INSTALL "${TO_INSTALL[@]}"; then ok "packages installed"
  else err "some packages failed to install — check output above"; fi
fi

# --- final verification of REQUIRED bins ---
echo; info "verifying required tools..."
fail=0
for e in "${REQ[@]}"; do bin="${e%%:*}"; command -v "$bin" >/dev/null && printf "   ${G}✔${N} %s\n" "$bin" || { printf "   ${R}✗${N} %s\n" "$bin"; fail=1; }; done

# make launcher executable
[ -f "$SCRIPT_DIR/launcher.sh" ] && chmod +x "$SCRIPT_DIR/launcher.sh" && ok "launcher.sh is executable"

echo
if [ "$fail" -eq 0 ]; then
  echo "   ${G}${W}✔ SETUP COMPLETE${N}"
  echo "   run the tool with:  ${C}sudo ./launcher.sh${N}   (or ${C}sudo ./launcher.sh auto${N})"
else
  echo "   ${R}${W}✗ some required tools are still missing — install them manually${N}"
  exit 1
fi
