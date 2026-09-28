#!/usr/bin/env bash
# Linux Mantenimiento 1.0.0 — Bash 4.3+, GNU find/coreutils.
set -u
set -o pipefail
umask 077

VERSION=1.0.0
MAX_FILES=50000
SCAN_TRUNCATED=0
if (( EUID == 0 )); then
  printf 'Ejecuta como usuario normal; la herramienta pedirá sudo solo para tareas del sistema.\n' >&2
  exit 2
fi
for cmd in find stat realpath id; do
  command -v "$cmd" >/dev/null || { printf 'Falta el comando: %s\n' "$cmd" >&2; exit 2; }
done
HOME_REAL=$(realpath -e -- "$HOME") || exit 2
[[ "$HOME_REAL" != / && ! -L "$HOME" ]] || { echo 'HOME no es seguro.' >&2; exit 2; }
CONFIG_ROOT=${XDG_CONFIG_HOME:-$HOME_REAL/.config}
mkdir -p -- "$CONFIG_ROOT/linux-mantenimiento" || exit 2
CONFIG_DIR=$(realpath -e -- "$CONFIG_ROOT/linux-mantenimiento") || exit 2
[[ "$CONFIG_DIR" == "$HOME_REAL/"* ]] || { echo 'El directorio de configuración debe estar en HOME.' >&2; exit 2; }
CONFIG="$CONFIG_DIR/config"
[[ ! -L "$CONFIG" ]] || { echo 'Rechazado: configuración es un enlace simbólico.' >&2; exit 2; }

declare -A ENABLED DAYS SEEN
declare -a CUSTOM_PATHS CUSTOM_DAYS CANDIDATES DEV INODE SIZE MTIME KIND
CUSTOM_PATHS=(); CUSTOM_DAYS=(); CANDIDATES=(); DEV=(); INODE=(); SIZE=(); MTIME=(); KIND=()
SEEN=()
IDS=(thumbs cache tmp pip history packages journal)
ENABLED=([thumbs]=1 [cache]=1 [tmp]=0 [pip]=0 [history]=0 [packages]=0 [journal]=0)
DAYS=([thumbs]=30 [cache]=60 [tmp]=14 [pip]=60 [history]=0 [packages]=0 [journal]=30)

valid_id() { local x; for x in "${IDS[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
valid_days() { [[ "$1" =~ ^[0-9]{1,4}$ ]] && (( 10#$1 <= 3650 )); }

safe_custom() {
  local raw=$1 resolved forbidden
  [[ -d "$raw" && ! -L "$raw" && "$raw" != *'|'* && "$raw" != *$'\n'* ]] || return 1
  resolved=$(realpath -e -- "$raw") || return 1
  [[ "$resolved" == "$HOME_REAL/"* && ! -L "$resolved" ]] || return 1
  for forbidden in .ssh .gnupg .config .local/share/keyrings Documents Downloads Desktop Pictures Videos Music; do
    [[ "$resolved" == "$HOME_REAL/$forbidden" || "$resolved" == "$HOME_REAL/$forbidden/"* ]] && return 1
  done
  [[ "$resolved" != "$HOME_REAL/.local" && "$resolved" != "$HOME_REAL/.cache" ]] || return 1
  printf '%s' "$resolved"
}

load_config() {
  local tag a b c extra path
  [[ -f "$CONFIG" ]] || return 0
  while IFS='|' read -r tag a b c extra || [[ -n "$tag" ]]; do
    case "$tag" in
      enabled) if valid_id "$a" && [[ "$b" == 0 || "$b" == 1 ]] && [[ -z "${c:-}" ]]; then ENABLED["$a"]=$b; fi ;;
      days) if valid_id "$a" && valid_days "$b" && [[ -z "${c:-}" ]]; then DAYS["$a"]=$b; fi ;;
      custom) if valid_days "$b" && [[ "$c" == 1 ]] && [[ -z "${extra:-}" ]]; then
          path=$(safe_custom "$a") && { CUSTOM_PATHS+=("$path"); CUSTOM_DAYS+=("$b"); }
        fi ;;
    esac
  done < "$CONFIG"
}

save_config() {
  local tmp id i
  tmp=$(mktemp "$CONFIG_DIR/.config.XXXXXX") || return 1
  for id in "${IDS[@]}"; do
    printf 'enabled|%s|%s\ndays|%s|%s\n' "$id" "${ENABLED[$id]}" "$id" "${DAYS[$id]}" >> "$tmp"
  done
  for ((i=0; i<${#CUSTOM_PATHS[@]}; i++)); do
    printf 'custom|%s|%s|1\n' "${CUSTOM_PATHS[i]}" "${CUSTOM_DAYS[i]}" >> "$tmp"
  done
  mv -f -- "$tmp" "$CONFIG"
}
load_config

show_list() {
  local id i
  printf 'Linux Mantenimiento %s\nConfiguración: %s\n\n' "$VERSION" "$CONFIG"
  printf '%-12s %-9s %-8s %s\n' 'TAREA' 'ACTIVA' 'DÍAS' 'ALCANCE'
  for id in "${IDS[@]}"; do
    case "$id" in
      thumbs) desc='Miniaturas antiguas (~/.cache/thumbnails)' ;;
      cache) desc='Archivos antiguos de ~/.cache (sin seguir enlaces)' ;;
      tmp) desc='Archivos propios antiguos de /tmp y /var/tmp' ;;
      pip) desc='Caché de pip (~/.cache/pip)' ;;
      history) desc='Vaciar historiales Bash/Zsh persistidos' ;;
      packages) desc='APT autoclean o DNF clean packages' ;;
      journal) desc='Vacuum de diarios archivados de systemd' ;;
    esac
    printf '%-12s %-9s %-8s %s\n' "$id" "${ENABLED[$id]}" "${DAYS[$id]}" "$desc"
  done
  for ((i=0; i<${#CUSTOM_PATHS[@]}; i++)); do
    printf 'custom[%d]   activa    %-8s %q\n' "$i" "${CUSTOM_DAYS[i]}" "${CUSTOM_PATHS[i]}"
  done
}

health() {
  printf 'Sistema: '
  if [[ -r /etc/os-release ]]; then
    ( . /etc/os-release; printf '%s\n' "${PRETTY_NAME:-Linux}" )
  else printf 'Linux\n'; fi
  printf 'Kernel: %s\n' "$(uname -r)"
  printf 'Gestor de paquetes detectado: %s\n' "$PKG"
  printf '\nDisco:\n'; df -h -- "$HOME_REAL" / 2>/dev/null || true
  printf '\nInodos:\n'; df -i -- "$HOME_REAL" / 2>/dev/null || true
  printf '\nMemoria:\n'; free -h 2>/dev/null || true
  printf '\nCarga y tiempo activo:\n'; uptime 2>/dev/null || true
  if command -v systemctl >/dev/null; then
    printf '\nServicios fallidos (si hay systemd):\n'
    systemctl --failed --no-pager --no-legend 2>/dev/null || true
  fi
}

path_in_home() { [[ "$1" == "$HOME_REAL/"* ]]; }
scan_tree() {
  local base=$1 days=$2 label=$3 owner=${4:-0} path info
  [[ -d "$base" && ! -L "$base" ]] || return 0
  base=$(realpath -e -- "$base") || return 0
  if [[ "$label" != tmp && "$label" != custom* ]] && ! path_in_home "$base"; then return 0; fi
  # -P no sigue symlinks; -xdev evita cruzar sistemas montados; solo archivos regulares.
  while IFS= read -r -d '' path; do
    if (( ${#CANDIDATES[@]} >= MAX_FILES )); then SCAN_TRUNCATED=1; break; fi
    [[ -z "${SEEN[$path]+x}" && ! -L "$path" ]] || continue
    info=$(stat -c '%d %i %s %Y %u' -- "$path" 2>/dev/null) || continue
    read -r d n s m u <<< "$info"
    [[ "$u" == "$(id -u)" ]] || continue
    SEEN["$path"]=1
    CANDIDATES+=("$path"); DEV+=("$d"); INODE+=("$n"); SIZE+=("$s"); MTIME+=("$m"); KIND+=("$label")
  done < <(if [[ "$label" == cache ]]; then
    # Mantener pip y miniaturas bajo sus propios interruptores.
    find -P "$base" -xdev \( -path "$base/pip" -o -path "$base/thumbnails" \) -prune -o \
      -type f -mtime "+$days" -print0 2>/dev/null
  elif (( owner )); then
    find -P "$base" -xdev -type f -user "$(id -u)" -mtime "+$days" -print0 2>/dev/null
  else
    find -P "$base" -xdev -type f -mtime "+$days" -print0 2>/dev/null
  fi)
}

scan_history() {
  local path info d n s m u
  for path in "$HOME_REAL/.bash_history" "$HOME_REAL/.zsh_history"; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    info=$(stat -c '%d %i %s %Y %u' -- "$path" 2>/dev/null) || continue
    read -r d n s m u <<< "$info"
    [[ "$u" == "$(id -u)" && "$s" -gt 0 ]] || continue
    CANDIDATES+=("$path"); DEV+=("$d"); INODE+=("$n"); SIZE+=("$s"); MTIME+=("$m"); KIND+=(history)
  done
}

PKG=none
if command -v apt-get >/dev/null && [[ -f /etc/debian_version ]]; then PKG=apt
elif command -v dnf >/dev/null && [[ -f /etc/redhat-release ]]; then PKG=dnf
fi

scan() {
  local i total=0 count=${#CANDIDATES[@]}
  if [[ "${ENABLED[thumbs]}" == 1 ]]; then scan_tree "$HOME_REAL/.cache/thumbnails" "${DAYS[thumbs]}" thumbs; fi
  if [[ "${ENABLED[cache]}" == 1 ]]; then scan_tree "$HOME_REAL/.cache" "${DAYS[cache]}" cache; fi
  if [[ "${ENABLED[tmp]}" == 1 ]]; then
    scan_tree /tmp "${DAYS[tmp]}" tmp 1
    scan_tree /var/tmp "${DAYS[tmp]}" tmp 1
  fi
  if [[ "${ENABLED[pip]}" == 1 ]]; then scan_tree "$HOME_REAL/.cache/pip" "${DAYS[pip]}" pip; fi
  if [[ "${ENABLED[history]}" == 1 ]]; then scan_history; fi
  for ((i=0; i<${#CUSTOM_PATHS[@]}; i++)); do
    if safe_custom "${CUSTOM_PATHS[i]}" >/dev/null; then
      scan_tree "${CUSTOM_PATHS[i]}" "${CUSTOM_DAYS[i]}" "custom[$i]"
    fi
  done
  count=${#CANDIDATES[@]}
  for ((i=0; i<count; i++)); do ((total+=SIZE[i])); done
  printf '\nEscaneo: %d archivos, %s bytes candidatos (%s aproximados).\n' "$count" "$total" "$(numfmt --to=iec --suffix=B "$total" 2>/dev/null || printf '%s B' "$total")"
  (( SCAN_TRUNCATED )) && printf 'Límite alcanzado: se inspeccionarán como máximo %d archivos por ejecución.\n' "$MAX_FILES"
  for ((i=0; i<count && i<20; i++)); do printf '  %-10s %10s  %q\n' "${KIND[i]}" "${SIZE[i]}" "${CANDIDATES[i]}"; done
  (( count > 20 )) && printf '  ... y %d archivos más.\n' "$((count-20))"
  if [[ "${ENABLED[packages]}" == 1 ]]; then
    printf 'Paquetes: %s; limpieza de archivos descargados (tamaño no incluido).\n' "$PKG"
  fi
  if [[ "${ENABLED[journal]}" == 1 ]]; then
    printf 'Journal: eliminar diarios archivados con antigüedad superior a %s días (tamaño no incluido).\n' "${DAYS[journal]}"
  fi
  [[ "${ENABLED[history]}" == 1 ]] && printf 'Aviso: una sesión de shell abierta puede volver a escribir su historial al salir.\n'
  printf 'El escaneo no modifica archivos.\n'
}

run_cleanup() {
  local i path info d n s m u parent removed=0 skipped=0 failed=0
  for ((i=0; i<${#CANDIDATES[@]}; i++)); do
    path=${CANDIDATES[i]}
    [[ -f "$path" && ! -L "$path" ]] || { ((skipped+=1)); continue; }
    parent=$(realpath -e -- "$(dirname -- "$path")" 2>/dev/null) || { ((skipped+=1)); continue; }
    # Comprobación de contención inmediatamente antes de modificar.
    if [[ "${KIND[i]}" == tmp ]]; then
      [[ "$parent" == /tmp || "$parent" == /tmp/* || "$parent" == /var/tmp || "$parent" == /var/tmp/* ]] || { ((skipped+=1)); continue; }
    else
      path_in_home "$parent/guard" || { ((skipped+=1)); continue; }
    fi
    info=$(stat -c '%d %i %s %Y %u' -- "$path" 2>/dev/null) || { ((skipped+=1)); continue; }
    read -r d n s m u <<< "$info"
    if [[ "$d" != "${DEV[i]}" || "$n" != "${INODE[i]}" || "$s" != "${SIZE[i]}" || "$m" != "${MTIME[i]}" || "$u" != "$(id -u)" ]]; then
      ((skipped+=1)); continue
    fi
    if [[ "${KIND[i]}" == history ]]; then
      : > "$path" 2>/dev/null && ((removed+=1)) || ((failed+=1))
    else
      rm -f -- "$path" && ((removed+=1)) || ((failed+=1))
    fi
  done
  if [[ "${ENABLED[packages]}" == 1 && "$PKG" != none ]]; then
    if [[ "$PKG" == apt ]]; then
      sudo apt-get autoclean || ((failed+=1))
    else
      sudo dnf clean packages || ((failed+=1))
    fi
  fi
  if [[ "${ENABLED[journal]}" == 1 ]]; then
    if command -v journalctl >/dev/null; then
      sudo journalctl "--vacuum-time=${DAYS[journal]}d" || ((failed+=1))
    else
      printf 'journalctl no disponible.\n' >&2; ((failed+=1))
    fi
  fi
  printf 'Resultado: %d archivos procesados, %d omitidos por cambios/permisos, %d errores.\n' "$removed" "$skipped" "$failed"
  (( failed == 0 ))
}

do_run() {
  local auto=${1:-0} answer
  scan
  if (( !auto )); then
    [[ -t 0 ]] || { echo 'Sin terminal: usa --run --yes para confirmar explícitamente.' >&2; return 2; }
    printf '\nEscribe LIMPIAR para ejecutar estas tareas: '
    read -r answer || return 2
    [[ "$answer" == LIMPIAR ]] || { echo 'Cancelado.'; return 0; }
  fi
  run_cleanup
}

menu() {
  local choice id path days
  while :; do
    printf '\n1) Ver tareas  2) Escanear  3) Ejecutar  4) Activar/desactivar\n'
    printf '5) Ajustar días  6) Agregar carpeta  7) Quitar carpeta  8) Salud  0) Salir\nOpción: '
    read -r choice || return 0
    case "$choice" in
      1) show_list ;;
      2) scan ;;
      3) do_run 0 ;;
      4) show_list; printf 'ID de tarea: '; read -r id || continue
         if valid_id "$id"; then ENABLED["$id"]=$((1-ENABLED[$id])); save_config; else echo 'ID inválido.'; fi ;;
      5) printf 'ID de tarea: '; read -r id || continue
         printf 'Días (0..3650): '; read -r days || continue
         if valid_id "$id" && valid_days "$days"; then DAYS["$id"]=$days; save_config; else echo 'Valor inválido.'; fi ;;
      6) printf 'Carpeta dentro de HOME: '; read -r path || continue
         printf 'Borrar archivos con más de N días: '; read -r days || continue
         if valid_days "$days" && (( 10#$days > 0 )) && path=$(safe_custom "$path"); then
           CUSTOM_PATHS+=("$path"); CUSTOM_DAYS+=("$days"); save_config
         else echo 'Carpeta o antigüedad no permitida.'; fi ;;
      7) show_list; printf 'Índice custom[N]: '; read -r id || continue
         if [[ "$id" =~ ^[0-9]+$ ]] && (( id < ${#CUSTOM_PATHS[@]} )); then
           unset 'CUSTOM_PATHS[id]' 'CUSTOM_DAYS[id]'
           CUSTOM_PATHS=("${CUSTOM_PATHS[@]}"); CUSTOM_DAYS=("${CUSTOM_DAYS[@]}"); save_config
         else echo 'Índice inválido.'; fi ;;
      8) health ;;
      0) return 0 ;;
      *) echo 'Opción inválida.' ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Uso: linux_mantenimiento.sh [opción]
  --menu                   Menú interactivo (predeterminado)
  --list                   Tareas y configuración
  --health                 Diagnóstico básico sin cambios
  --scan                   Vista previa sin borrar
  --run                    Escanear, confirmar y ejecutar
  --run --yes              Confirmación explícita para automatización
  --enable ID              Activar tarea
  --disable ID             Desactivar tarea
  --set-days ID N          Ajustar antigüedad en días
  --add-path RUTA N        Agregar carpeta propia bajo HOME, N días
  --remove-path ÍNDICE     Quitar carpeta personalizada
  --help                   Mostrar ayuda
IDs: thumbs cache tmp pip history packages journal
EOF
}

case "${1:---menu}" in
  --menu) menu ;;
  --list) show_list ;;
  --health) health ;;
  --scan) scan ;;
  --run) [[ "${2:-}" == --yes ]] && do_run 1 || do_run 0 ;;
  --enable|--disable) valid_id "${2:-}" || { echo 'ID inválido.' >&2; exit 2; }
      [[ "$1" == --enable ]] && ENABLED["$2"]=1 || ENABLED["$2"]=0; save_config ;;
  --set-days) valid_id "${2:-}" && valid_days "${3:-}" || { echo 'Parámetros inválidos.' >&2; exit 2; }
      DAYS["$2"]=$3; save_config ;;
  --add-path) valid_days "${3:-}" && (( 10#${3:-0} > 0 )) && path=$(safe_custom "${2:-}") || { echo 'Carpeta/antigüedad no permitida.' >&2; exit 2; }
      CUSTOM_PATHS+=("$path"); CUSTOM_DAYS+=("$3"); save_config ;;
  --remove-path) idx=${2:-}; [[ "$idx" =~ ^[0-9]+$ ]] && (( idx < ${#CUSTOM_PATHS[@]} )) || { echo 'Índice inválido.' >&2; exit 2; }
      unset 'CUSTOM_PATHS[idx]' 'CUSTOM_DAYS[idx]'; CUSTOM_PATHS=("${CUSTOM_PATHS[@]}"); CUSTOM_DAYS=("${CUSTOM_DAYS[@]}"); save_config ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
