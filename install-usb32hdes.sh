#!/usr/bin/env bash
set -Eeuo pipefail

# Instalador/validador para StarTech USB32HDES (MCT T6 / Trigger T6-688SL)
# Uso: sudo ./install-usb32hdes.sh [install|verify|backup|uninstall|help]
#
# El driver de MCT trae EVDI 1.14.8, que no compila en el kernel 7.0 de
# Ubuntu 26.04. Este script detecta el caso y elige el EVDI adecuado.

readonly SELF="$(readlink -f "$0")"
readonly SCRIPT_NAME="$(basename "$SELF")"
readonly RUN_URL="https://raw.githubusercontent.com/carlosmax3D/startech-usba-hdmi-linux-driver/main/ubuntu_T6_250422.run"
readonly EVDI_VER="1.15.1"
readonly EVDI_URL="https://github.com/DisplayLink/evdi/archive/refs/tags/v${EVDI_VER}.tar.gz"
readonly VIDPID="0711:5601"
readonly LOG_FILE="/var/log/usb32hdes-install.log"

FORCE=0
ASSUME_YES=0
ALLOW_WAYLAND=0
SESSION_TYPE=""
BUILD_DIR=""
RUN_FILE=""
EVDI_FILE=""
EVDI_DIR=""
T6_DIR=""
EVDI_SOURCE=""
EVDI_LIB_VER=""
EVDI_LIB_FILE=""
OS_ID=""
OS_VERSION_ID=""
OS_PRETTY=""
KREL=""

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
trap 'cleanup_build' EXIT

cleanup_build() {
  if [[ -n "${BUILD_DIR:-}" && -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
  fi
}

usage() {
  cat <<EOF
Uso: sudo ./$SCRIPT_NAME [opciones] [comando]

Comandos:
  install     Detecta el sistema, elige el EVDI adecuado, compila e instala
  verify      Comprueba el estado tras el reinicio
  backup      Solo crea el backup de configuración
  uninstall   Desinstala el driver y libera el kernel
  help        Muestra esta ayuda

Opciones:
  --force           Reinstala aunque T6evdi ya esté presente
  --yes             No pide confirmación
  --allow-wayland   Permite instalar en Wayland (no funcionará hasta usar X11)

Detección automática:
  - Ubuntu 24.04 + kernel 6.8: usa el EVDI incluido en el .run de MCT.
  - Ubuntu 26.04 / kernel 7.x u otros: usa EVDI $EVDI_VER de DisplayLink.
  - Sesión X11: instala y arranca T6evdi.
  - Sesión Wayland: se bloquea salvo --allow-wayland; no habrá salida de vídeo.
EOF
}

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local ans
  read -r -p "$1 [s/N] " ans
  [[ "$ans" =~ ^[sSyY]$ ]]
}

# Identifica distro y versión de kernel, y decide la variante de EVDI
# que corresponde:
#   - Ubuntu 24.04 con kernel 6.8: EVDI incluido en el .run de MCT (conocido bueno)
#   - kernels modernos (7.x) o cualquier otro caso: EVDI upstream 1.15.1
detect_system() {
  [[ -r /etc/os-release ]] || die "no se encuentra /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_PRETTY="${PRETTY_NAME:-desconocido}"

  KREL="$(uname -r)"
  local kmaj="${KREL%%.*}"
  local kmin="${KREL#*.}"
  kmin="${kmin%%.*}"
  [[ "$kmaj" =~ ^[0-9]+$ ]] || kmaj=0
  [[ "$kmin" =~ ^[0-9]+$ ]] || kmin=0

  if [[ "$OS_ID" != "ubuntu" ]]; then
    warn "distro no Ubuntu detectada ($OS_PRETTY); el driver está pensado para Ubuntu"
  fi

  if (( kmaj >= 7 )) || [[ "$OS_VERSION_ID" == 26.* ]]; then
    EVDI_SOURCE="upstream"
  elif [[ "$OS_VERSION_ID" == "24.04" && "$KREL" == 6.8.* ]]; then
    EVDI_SOURCE="bundled"
  else
    EVDI_SOURCE="upstream"
  fi

  log "Sistema detectado: $OS_PRETTY / kernel $KREL"
  if [[ "$EVDI_SOURCE" == "upstream" ]]; then
    log "Variante elegida: EVDI $EVDI_VER de DisplayLink (kernels modernos)"
  else
    log "Variante elegida: EVDI incluido en el .run de MCT (Ubuntu 24.04 / kernel 6.8)"
  fi
}

check_os() {
  [[ -n "$OS_ID" ]] || detect_system
  [[ "$OS_ID" == "ubuntu" ]] || warn "probado en Ubuntu; detectado: ${OS_PRETTY:-desconocido}"
  local major="${OS_VERSION_ID%%.*}"
  [[ "${major:-0}" -ge 24 ]] || die "se requiere Ubuntu 24.04 o superior (detectado ${OS_VERSION_ID:-?})"
  log "OS: ${OS_PRETTY:-?}"
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
      warn "Secure Boot activado: el módulo evdi no está firmado."
      warn "Desactiva Secure Boot o firma /lib/modules/$(uname -r)/kernel/drivers/video/evdi.ko."
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
  SESSION_TYPE="$type"
  if [[ "$type" == "wayland" ]]; then
    if [[ "$ALLOW_WAYLAND" -eq 1 ]]; then
      warn "Sesión Wayland detectada; se instalará, pero EVDI no funcionará hasta entrar en X11."
    else
      die "sesión Wayland detectada: EVDI/T6 solo funciona en X11. Instala/elige una sesión X11 (p. ej. sudo apt install xfce4), vuelve a entrar en ella o usa --allow-wayland."
    fi
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
  curl -fsSIL --max-time 20 "$RUN_URL" >/dev/null \
    || die "no se puede descargar el instalador desde $RUN_URL"
  if [[ "$EVDI_SOURCE" == "upstream" ]]; then
    curl -fsSIL --max-time 20 "$EVDI_URL" >/dev/null \
      || die "no se puede descargar EVDI desde $EVDI_URL"
  fi
  log "Conectividad con los mirrors: OK"
}

install_deps() {
  log "Instalando dependencias..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential gcc make curl ca-certificates python3 usbutils x11-xserver-utils \
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
  local dest="$1" part="$1.part"
  log "Descargando $RUN_URL"
  rm -f "$part"
  curl -fL --retry 3 --max-time 120 -o "$part" "$RUN_URL"
  mv -f "$part" "$dest"
  chmod +x "$dest"
  log "Descargado: $dest ($(stat -c%s "$dest") bytes)"
}

download_evdi() {
  local dest="$1" part="$1.part"
  log "Descargando EVDI $EVDI_VER desde $EVDI_URL"
  rm -f "$part"
  curl -fL --retry 3 --max-time 180 -o "$part" "$EVDI_URL"
  mv -f "$part" "$dest"
  log "Descargado: $dest ($(stat -c%s "$dest") bytes)"
}

# Extrae el payload del .run y deja las fuentes del demonio T6 en $T6_DIR.
extract_t6_sources() {
  local inner="$BUILD_DIR/inner.tar.gz"
  python3 - "$RUN_FILE" "$inner" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
idx = data.find(b'\x1f\x8b')
if idx < 0:
    sys.exit('no se encontró payload gzip')
open(out, 'wb').write(data[idx:])
PY

  local listing
  listing="$(tar tzf "$inner")"
  grep -qx 'evdi_t6.tar.gz' <<<"$listing" || die "falta evdi_t6.tar.gz en el instalador de MCT"

  tar xzf "$inner" -C "$BUILD_DIR" evdi_t6.tar.gz
  tar xzf "$BUILD_DIR/evdi_t6.tar.gz" -C "$BUILD_DIR"

  T6_DIR="$BUILD_DIR/evdi_t6_1"
  [[ -d "$T6_DIR" ]] || die "no se encontró evdi_t6_1 dentro del instalador de MCT"
  [[ -f "$T6_DIR/main.c" ]] || die "no se encontró main.c del demonio T6"
  grep -q '0x0711' "$T6_DIR/main.c" || die "main.c no contiene el VID 0x0711"
  grep -q '0x5600' "$T6_DIR/main.c" || die "main.c no contiene el mask 0x5600"
  log "Fuentes del demonio T6: OK (VID 0x0711 / PID 0x56xx)"
}

extract_evdi_sources() {
  if [[ "$EVDI_SOURCE" == "upstream" ]]; then
    [[ -f "$EVDI_FILE" ]] || die "falta $EVDI_FILE; descarga EVDI $EVDI_VER"
    tar xzf "$EVDI_FILE" -C "$BUILD_DIR"
    EVDI_DIR="$BUILD_DIR/evdi-$EVDI_VER"
  else
    local inner="$BUILD_DIR/inner.tar.gz"
    local listing
    [[ -f "$inner" ]] || die "falta el payload del instalador de MCT"
    listing="$(tar tzf "$inner")"
    grep -qx 'evdi.tar.gz' <<<"$listing" || die "falta evdi.tar.gz en el instalador de MCT"
    tar xzf "$inner" -C "$BUILD_DIR" evdi.tar.gz
    tar xzf "$BUILD_DIR/evdi.tar.gz" -C "$BUILD_DIR"
    EVDI_DIR="$BUILD_DIR/evdi"
  fi
  [[ -f "$EVDI_DIR/Makefile" ]] || die "no se encontró el Makefile de EVDI"

  # Los Makefiles de EVDI usan -Werror; los headers modernos generan warnings
  # de sign-compare que rompen la compilación aunque el código sea correcto.
  sed -i -e 's/^FLAGS=-Werror /FLAGS=/' -e 's/ -Werror=sign-compare//' "$EVDI_DIR/Makefile"
  log "Fuentes de EVDI preparadas (sin -Werror)"
}

build_evdi() {
  local label="EVDI upstream $EVDI_VER"
  [[ "$EVDI_SOURCE" == "bundled" ]] && label="EVDI incluido en MCT"

  log "Compilando módulo evdi ($label)..."
  make -C "$EVDI_DIR" module
  log "Compilando librería libevdi ($label)..."
  make -C "$EVDI_DIR" library

  [[ -f "$EVDI_DIR/module/evdi.ko" ]] || die "no se generó module/evdi.ko"

  EVDI_LIB_FILE="$(find "$EVDI_DIR/library" -maxdepth 1 -type f -name 'libevdi.so.[0-9]*' -print | sort -V | tail -n1)"
  [[ -n "$EVDI_LIB_FILE" ]] || die "no se generó la librería libevdi"
  EVDI_LIB_VER="${EVDI_LIB_FILE##*/libevdi.so.}"
  log "EVDI compilado correctamente (libevdi.so.$EVDI_LIB_VER)"
}

build_t6() {
  log "Compilando demonio T6evdi contra EVDI $EVDI_VER..."
  make -C "$T6_DIR" clean >/dev/null 2>&1 || true
  make -C "$T6_DIR" \
    CFLAGS="-I$EVDI_DIR/library" \
    LDFLAGS="-L$EVDI_DIR/library -Wl,-rpath,/usr/lib -levdi -lusb-1.0 -lturbojpeg -lc -lm -lpthread"

  [[ -x "$T6_DIR/T6evdi" ]] || die "no se generó T6evdi"
  [[ -x "$T6_DIR/T6contrl" ]] || die "no se generó T6contrl"
  log "Demonio T6 compilado correctamente"
}

install_driver() {
  local krel moddir
  krel="$(uname -r)"
  moddir="/lib/modules/$krel/kernel/drivers/video"

  log "Instalando módulo y librería EVDI (libevdi.so.$EVDI_LIB_VER)..."
  install -d "$moddir"
  install -m 644 "$EVDI_DIR/module/evdi.ko" "$moddir/evdi.ko"

  rm -f /usr/lib/libevdi.so.1.14.* /usr/lib/libevdi.so.1.15.*
  install -m 644 "$EVDI_LIB_FILE" "/usr/lib/libevdi.so.$EVDI_LIB_VER"
  ln -sfn "libevdi.so.$EVDI_LIB_VER" /usr/lib/libevdi.so.1
  ln -sfn "libevdi.so.$EVDI_LIB_VER" /usr/lib/libevdi.so.0
  ln -sfn "libevdi.so.$EVDI_LIB_VER" /usr/lib/libevdi.so
  install -m 644 "$EVDI_DIR/library/evdi_lib.h" /usr/include/evdi_lib.h

  log "Instalando T6evdi y T6contrl..."
  install -m 755 "$T6_DIR/T6evdi" /usr/sbin/T6evdi
  install -m 755 "$T6_DIR/T6contrl" /usr/sbin/T6contrl

  install -m 644 "$T6_DIR/evdi.conf" /etc/modprobe.d/evdi.conf
  install -m 644 "$T6_DIR/T6evdi.service" /etc/systemd/system/T6evdi.service
  install -m 644 "$T6_DIR/T6poweron.service" /etc/systemd/system/T6poweron.service
  install -m 644 "$T6_DIR/T6powerdown.service" /etc/systemd/system/T6powerdown.service

  touch /etc/modules
  grep -qx 'evdi' /etc/modules || echo 'evdi' >> /etc/modules

  systemctl daemon-reload
  if [[ "$SESSION_TYPE" == "wayland" ]]; then
    # En Wayland T6evdi no puede capturar buffers; se deja preparado pero
    # parado para no gastar CPU hasta que el usuario entre en X11.
    systemctl enable T6poweron T6powerdown >/dev/null 2>&1 || true
    systemctl disable --now T6evdi >/dev/null 2>&1 || true
  else
    systemctl enable T6evdi T6poweron T6powerdown >/dev/null 2>&1 || true
  fi
  ldconfig
  depmod -a "$krel"
  log "Instalación de archivos completada"
}

hold_kernel() {
  log "Bloqueando actualizaciones de kernel para no romper evdi..."
  apt-mark hold linux-generic linux-image-generic linux-headers-generic >/dev/null 2>&1 || true
}

start_driver() {
  if [[ "$SESSION_TYPE" == "wayland" ]]; then
    warn "No se arranca T6evdi en Wayland; hazlo al entrar en una sesión X11."
    return 0
  fi

  log "Cargando evdi y arrancando T6evdi..."
  systemctl stop T6evdi T6poweron T6powerdown 2>/dev/null || true
  modprobe -r evdi 2>/dev/null || true
  modprobe evdi
  if systemctl start T6evdi; then
    log "T6evdi arrancado"
  else
    warn "T6evdi no arrancó; revisa: journalctl -u T6evdi -b --no-pager"
  fi
}

do_install() {
  detect_system
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

  local evdi_desc="EVDI upstream $EVDI_VER"
  [[ "$EVDI_SOURCE" == "bundled" ]] && evdi_desc="EVDI incluido en MCT"
  confirm "Se instalará $evdi_desc + el driver T6 y se reiniciará el servicio. ¿Continuar?" \
    || die "cancelado por el usuario"

  install_deps
  do_backup

  # Descargas y compilación en un directorio privado (700) del usuario que
  # ejecuta el script. Evita los ficheros fijos de /tmp, que pueden pertenecer
  # a otro usuario y provocar "Permission denied" con fs.protected_regular=2.
  BUILD_DIR="$(mktemp -d /tmp/usb32hdes-build.XXXXXX)"
  log "Directorio de compilación: $BUILD_DIR"
  RUN_FILE="$BUILD_DIR/${RUN_URL##*/}"
  EVDI_FILE="$BUILD_DIR/evdi-${EVDI_VER}.tar.gz"

  download_run "$RUN_FILE"
  if [[ "$EVDI_SOURCE" == "upstream" ]]; then
    download_evdi "$EVDI_FILE"
  fi

  extract_t6_sources
  extract_evdi_sources
  build_evdi
  build_t6
  install_driver
  start_driver
  hold_kernel

  log "Instalación completada."
  if [[ "$SESSION_TYPE" == "wayland" ]]; then
    warn "Estás en Wayland: el adaptador no aparecerá hasta que uses una sesión X11."
  else
    log "Comprueba con: sudo ./$SCRIPT_NAME verify"
    log "Si la pantalla no aparece aún, reinicia el equipo."
  fi
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
  done

  # T6poweron/T6powerdown son hooks de suspend/resume: inactivos es lo normal.
  if systemctl is-active --quiet T6evdi 2>/dev/null; then
    log "T6evdi: active"
  elif [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    warn "T6evdi: no active (esperado en Wayland; entra en una sesión X11)"
  else
    warn "T6evdi: no active"
    fail=1
  fi

  if [[ -e "/lib/modules/$(uname -r)/kernel/drivers/video/evdi.ko" ]]; then
    log "evdi.ko: presente"
  else
    warn "evdi.ko: ausente"
    fail=1
  fi

  if [[ -e /usr/lib/libevdi.so.1 ]]; then
    log "libevdi: $(basename "$(readlink -f /usr/lib/libevdi.so.1)")"
  else
    warn "libevdi.so.1: ausente"
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
    warn "no se pudo consultar xrandr (¿sesión X11 activa?)"
  fi

  log "Últimas líneas de T6evdi:"
  journalctl -u T6evdi -b --no-pager 2>/dev/null | tail -20 || true

  if (( fail )); then
    warn "Verificación con errores. Revisa: journalctl -u T6evdi -b"
    return 1
  fi
  log "Verificación completada correctamente."
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

do_uninstall() {
  confirm "Se desinstalará el driver T6. ¿Continuar?" || die "cancelado por el usuario"

  systemctl disable --now T6evdi T6poweron T6powerdown 2>/dev/null || true
  rm -f /etc/systemd/system/T6evdi.service \
        /etc/systemd/system/T6poweron.service \
        /etc/systemd/system/T6powerdown.service
  rm -f /usr/sbin/T6evdi /usr/sbin/T6contrl
  rm -f /usr/lib/libevdi.so /usr/lib/libevdi.so.0 /usr/lib/libevdi.so.1 \
        /usr/lib/libevdi.so.1.14.* /usr/lib/libevdi.so.1.15.*
  rm -f /usr/include/evdi_lib.h
  rm -f /etc/modprobe.d/evdi.conf
  rm -f "/lib/modules/$(uname -r)/kernel/drivers/video/evdi.ko"
  sed -i '/^evdi$/d' /etc/modules 2>/dev/null || true
  systemctl daemon-reload
  ldconfig
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
      --allow-wayland) ALLOW_WAYLAND=1 ;;
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
