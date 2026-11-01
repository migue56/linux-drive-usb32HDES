#!/usr/bin/env bash
set -Eeuo pipefail

# Instalador/validador para StarTech USB32HDES (MCT T6 / Trigger T6-688SL)
# Uso: sudo ./install-usb32hdes.sh [install|verify|backup|uninstall|help]

readonly SELF="$(readlink -f "$0")"
readonly SCRIPT_NAME="$(basename "$SELF")"
readonly RUN_URL="https://raw.githubusercontent.com/carlosmax3D/startech-usba-hdmi-linux-driver/main/ubuntu_T6_250422.run"
readonly RUN_FILE="/tmp/ubuntu_T6_250422.run"
readonly VIDPID="0711:5601"
readonly LOG_FILE="/var/log/usb32hdes-install.log"

FORCE=0
ASSUME_YES=0

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$SELF" "$@"
fi

ORIG_USER="${SUDO_USER:-root}"
ORIG_HOME="$(getent passwd "$ORIG_USER" | cut -d: -f6)"
BACKUP_DIR="$ORIG_HOME/backup-t6"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

trap 'die "fallo en la línea $LINENO"' ERR

usage() {
  cat <<EOF
Uso: sudo ./$SCRIPT_NAME [opciones] [comando]

Comandos:
  install     Valida el sistema, descarga el driver e instala (reinicia)
  verify      Comprueba el estado tras el reinicio
  backup      Solo crea el backup de configuración
  uninstall   Desinstala el driver y libera el kernel
  help        Muestra esta ayuda

Opciones:
  --force     Reinstala aunque T6evdi ya esté presente
  --yes       No pide confirmación
EOF
}

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local ans
  read -r -p "$1 [s/N] " ans
  [[ "$ans" =~ ^[sSyY]$ ]]
}

check_os() {
  [[ -r /etc/os-release ]] || die "no se encuentra /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "probado en Ubuntu; detectado: ${PRETTY_NAME:-desconocido}"
  local major="${VERSION_ID%%.*}"
  [[ "${major:-0}" -ge 24 ]] || die "se requiere Ubuntu 24.04 o superior (detectado ${VERSION_ID:-?})"
  log "OS: ${PRETTY_NAME:-?}"
}

check_kernel_headers() {
  local krel; krel="$(uname -r)"
  dpkg -s "linux-headers-$krel" >/dev/null 2>&1 \
    || die "faltan headers para el kernel $krel (instala linux-headers-$krel)"
  log "Kernel/headers: $krel"
}

check_secure_boot() {
  if command -v mokutil >/dev/null 2>&1; then
    local sb
    sb="$(mokutil --sb-state 2>/dev/null || true)"
    if grep -qi enabled <<<"$sb"; then
      warn "Secure Boot activado: el instalador pedirá enrolar una clave MOK."
      warn "Si no quieres firmar módulos, desactiva Secure Boot en la UEFI."
    else
      log "Secure Boot: desactivado"
    fi
  else
    warn "mokutil no instalado; no se puede comprobar Secure Boot"
  fi
}

check_session() {
  local type="${XDG_SESSION_TYPE:-}"
  if [[ -z "$type" ]]; then
    type="$(loginctl show-session "$(loginctl | awk 'NR==2{print $1}')" -p Type --value 2>/dev/null || true)"
  fi
  if [[ "$type" == "wayland" ]]; then
    warn "sesión Wayland detectada; EVDI funciona mejor en X11"
  else
    log "Sesión gráfica: ${type:-desconocida}"
  fi
}

check_device() {
  if lsusb -d "$VIDPID" >/dev/null 2>&1; then
    log "Dispositivo detectado: $(lsusb -d "$VIDPID")"
  else
    warn "no se detecta $VIDPID; conecta el USB32HDES antes de continuar"
  fi
}

check_disk() {
  local avail; avail="$(df -Pk / | awk 'NR==2{print $4}')"
  (( avail > 2 * 1024 * 1024 )) || die "espacio insuficiente en / (necesarios ~2 GB)"
  log "Espacio libre en /: $(( avail / 1024 / 1024 )) GB"
}

check_network() {
  curl -fsSI --max-time 20 "$RUN_URL" >/dev/null \
    || die "no se puede descargar el instalador desde $RUN_URL"
  log "Conectividad con el mirror: OK"
}

install_deps() {
  log "Instalando dependencias..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential gcc make curl ca-certificates usbutils x11-xserver-utils \
    libusb-1.0-0-dev libdrm-dev libelf-dev libturbojpeg0-dev
}

do_backup() {
  mkdir -p "$BACKUP_DIR"
  local stamp out
  stamp="$(date +%F_%H%M%S)"
  out="$BACKUP_DIR/evdi-backup-$stamp.tar.gz"
  log "Creando backup en $out"
  tar czf "$out" --ignore-failed-read \
    /etc/modules /etc/modprobe.d /usr/lib/libevdi* /usr/include/evdi_lib.h \
    /etc/systemd/system/T6*.service 2>/dev/null || true
  {
    echo "kernel=$(uname -r)"
    echo "fecha=$stamp"
    echo "held:"
    apt-mark showhold || true
  } > "$BACKUP_DIR/estado-$stamp.txt"
  log "Backup: $out"
}

download_run() {
  log "Descargando $RUN_URL"
  curl -fL --retry 3 --max-time 120 -o "$RUN_FILE" "$RUN_URL"
  chmod +x "$RUN_FILE"
  log "Descargado: $RUN_FILE ($(stat -c%s "$RUN_FILE") bytes)"
}

validate_run() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  python3 - "$RUN_FILE" "$tmp/inner.tar.gz" <<'PY' || rc=$?
import sys
src, out = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
idx = data.find(b'\x1f\x8b')
if idx < 0:
    sys.exit('no se encontró payload gzip')
open(out, 'wb').write(data[idx:])
PY
  (( rc == 0 )) || die "el instalador no contiene un payload gzip válido"

  local inner_listing
  inner_listing="$(tar tzf "$tmp/inner.tar.gz")"
  grep -qx 'evdi.tar.gz' <<<"$inner_listing" || die "falta evdi.tar.gz en el instalador"
  grep -qx 'evdi_t6.tar.gz' <<<"$inner_listing" || die "falta evdi_t6.tar.gz en el instalador"

  tar xzOf "$tmp/inner.tar.gz" evdi_t6.tar.gz > "$tmp/evdi_t6.tar.gz"
  local t6_listing mainc
  t6_listing="$(tar tzf "$tmp/evdi_t6.tar.gz")"
  mainc="$(grep -m1 -E '(^|/)main\.c$' <<<"$t6_listing" || true)"
  [[ -n "$mainc" ]] || die "no se encuentra main.c dentro de evdi_t6.tar.gz"
  tar xzOf "$tmp/evdi_t6.tar.gz" "$mainc" > "$tmp/main.c"

  grep -q '0x0711' "$tmp/main.c" || die "main.c no contiene el VID 0x0711"
  grep -q '0x5600' "$tmp/main.c" || die "main.c no contiene el mask 0x5600"

  log "Validación del instalador: OK (soporta VID 0x0711 / PID 0x56xx)"
  rm -rf "$tmp"
}

run_xrandr() {
  local psout xdisp xauth
  psout="$(ps -eo args)"
  xdisp="$(awk '/[X]org/ { for (i=1;i<=NF;i++) if ($i ~ /^:[0-9]+$/) { print $i; exit } }' <<<"$psout")"
  xauth="$(awk '/[X]org/ { for (i=1;i<=NF;i++) if ($i == "-auth") { print $(i+1); exit } }' <<<"$psout")"
  [[ -n "$xdisp" ]] || return 1
  if [[ -n "$xauth" ]]; then
    DISPLAY="$xdisp" XAUTHORITY="$xauth" xrandr "$@"
  else
    DISPLAY="$xdisp" xrandr "$@"
  fi
}

do_install() {
  check_os
  check_kernel_headers
  check_secure_boot
  check_session
  check_device
  check_disk
  check_network

  if [[ -x /usr/sbin/T6evdi && "$FORCE" -ne 1 ]]; then
    warn "T6evdi ya está instalado. Usa --force para reinstalar."
    exit 0
  fi

  confirm "Se instalará el driver T6 y el equipo se reiniciará. ¿Continuar?" \
    || die "cancelado por el usuario"

  install_deps
  do_backup
  download_run
  validate_run

  log "Ejecutando el instalador de MCT. El equipo se reiniciará al terminar."
  log "Tras el reinicio, ejecuta: sudo ./$SCRIPT_NAME verify"
  "$RUN_FILE"
}

do_verify() {
  local fail=0

  if grep -q '^evdi' <<<"$(lsmod)"; then
    log "evdi: cargado"
  else
    warn "evdi: NO cargado"
    fail=1
  fi

  local svc
  for svc in T6evdi T6poweron T6powerdown; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      log "$svc: enabled"
    else
      warn "$svc: no enabled"
    fi
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      log "$svc: active"
    else
      warn "$svc: no active"
      fail=1
    fi
  done

  if [[ -e "/lib/modules/$(uname -r)/kernel/drivers/video/evdi.ko" ]]; then
    log "evdi.ko: presente"
  else
    warn "evdi.ko: ausente"
    fail=1
  fi

  if lsusb -d "$VIDPID" >/dev/null 2>&1; then
    log "USB32HDES: presente"
  else
    warn "USB32HDES: ausente"
    fail=1
  fi

  if run_xrandr --query >/dev/null 2>&1; then
    log "Salidas X detectadas:"
    run_xrandr --query | grep -E 'connected|disconnected' || true
    if grep -qi evdi <<<"$(run_xrandr --listproviders 2>/dev/null || true)"; then
      log "Proveedor evdi: presente"
    else
      warn "Proveedor evdi no listado; revisa journalctl -u T6evdi -b"
    fi
  else
    warn "no se pudo consultar xrandr (¿sesión gráfica activa?)"
  fi

  log "Últimas líneas de T6evdi:"
  journalctl -u T6evdi -b --no-pager 2>/dev/null | tail -20 || true

  if (( fail )); then
    warn "Verificación con errores. Revisa: journalctl -u T6evdi -b"
    return 1
  fi
  log "Verificación completada correctamente."
}

do_uninstall() {
  confirm "Se desinstalará el driver T6. ¿Continuar?" || die "cancelado por el usuario"

  systemctl disable --now T6evdi T6poweron T6powerdown 2>/dev/null || true
  rm -f /etc/systemd/system/T6evdi.service \
        /etc/systemd/system/T6poweron.service \
        /etc/systemd/system/T6powerdown.service
  rm -f /usr/sbin/T6evdi /usr/sbin/T6contrl
  rm -f /usr/lib/libevdi.so /usr/lib/libevdi.so.0 /usr/lib/libevdi.so.1 /usr/lib/libevdi.so.1.14.2
  rm -f /usr/include/evdi_lib.h
  rm -f "/lib/modules/$(uname -r)/kernel/drivers/video/evdi.ko"
  sed -i '/^evdi$/d' /etc/modules 2>/dev/null || true
  systemctl daemon-reload
  depmod -a

  apt-mark unhold linux-generic linux-image-generic linux-headers-generic 2>/dev/null || true

  log "Desinstalación completada. Reinicia el equipo."
}

parse_args() {
  local args=()
  local a
  for a in "$@"; do
    case "$a" in
      --force) FORCE=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      *) args+=("$a") ;;
    esac
  done
  if (( ${#args[@]} )); then
    set -- "${args[@]}"
  else
    set --
  fi
  CMD="${1:-install}"
}

parse_args "$@"

case "$CMD" in
  install)   do_install ;;
  verify)    do_verify ;;
  backup)    do_backup ;;
  uninstall) do_uninstall ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
