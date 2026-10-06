#!/usr/bin/env bash
#
# backup.sh — Copias de seguridad comprimidas (tar.gz) con verificación,
# suma SHA-256 y política de retención diaria/semanal.
#
# Para cada ejecución:
#   1. bloquea el destino con flock (no puede haber dos copias a la vez)
#   2. crea PREFIJO_AAAA-MM-DD_HHMMSS.tar.gz en un fichero temporal «.part»
#   3. verifica el archivo leyéndolo entero (tar --list)
#   4. lo renombra a su nombre definitivo y escribe su .sha256 al lado
#   5. aplica la retención y borra las copias antiguas de ese prefijo
#
# Códigos de salida:
#   0 copia correcta · 1 error · 2 error de uso · 3 ya hay otra copia en curso
#
# Autor: Miguel Ángel Alonso Valhondo — Licencia MIT

set -Eeuo pipefail

DIR_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/comun.sh
source "${DIR_SCRIPT}/../lib/comun.sh"

readonly CODIGO_BLOQUEO=3
activar_trampa_errores

# Opciones y valores por defecto.
DESTINO=""
PREFIJO="backup"
MANTENER_DIARIAS=7
MANTENER_SEMANALES=4
SIMULACION=0
ORIGENES=()
EXCLUSIONES=()

# Fichero temporal en curso: si el script termina antes de tiempo, la
# función limpiar() lo borra para no dejar copias a medias.
TEMPORAL_EN_CURSO=""
# PID de tar mientras se ejecuta y fichero donde se guardan sus errores.
PID_TAR=""
FICHERO_ERRORES_TAR=""

mostrar_ayuda() {
  cat <<'AYUDA'
Uso: backup.sh -d DESTINO [opciones] ORIGEN [ORIGEN...]

Crea una copia comprimida (tar.gz) de uno o varios directorios en DESTINO,
la verifica, guarda su suma SHA-256 y borra las copias antiguas según la
política de retención.

Nombre de cada copia:  PREFIJO_AAAA-MM-DD_HHMMSS.tar.gz  (+ .sha256)
Las rutas se guardan relativas a «/» (etc/nginx/...). Para restaurar:
  tar -xzf web_2026-10-06_030000.tar.gz -C /ruta/de/restauracion

Opciones:
  -d, --destino DIR      directorio donde se guardan las copias (se crea si no existe)
  -n, --nombre PREFIJO   prefijo de los ficheros (por defecto «backup»); la
                         retención solo toca las copias con este prefijo
  -e, --exclude PATRÓN   excluye ficheros o directorios (patrón de tar, ej.
                         '*.log', 'node_modules'); se puede repetir
      --keep-daily N     copias diarias a conservar (por defecto 7, mínimo 1)
      --keep-weekly N    copias semanales a conservar (por defecto 4)
      --dry-run          muestra lo que haría sin escribir ni borrar nada
      --log FICHERO      añade los mensajes a un fichero de log
  -q, --quiet            solo muestra errores
  -v, --verbose          muestra más detalle (motivo de cada copia conservada)
  -h, --help             muestra esta ayuda
      --version          muestra la versión

Retención (dos reglas independientes; una copia se conserva si la elige
alguna de ellas, y el resto de copias de ese prefijo se borran):
  · diaria:  de los N días más recientes que tienen copias, se conserva la
             copia más reciente de cada día.
  · semanal: de las N semanas ISO (lunes a domingo) más recientes que tienen
             copias, se conserva la copia más reciente de cada semana.
  La fecha se toma del nombre del fichero, no de la fecha de modificación.
  La copia recién creada siempre se conserva (es la más reciente de su día).

Códigos de salida:
  0 correcto · 1 error (tar, verificación, permisos...) · 2 error de uso
  3 otra ejecución con el mismo destino y prefijo está en curso

Ejemplos:
  backup.sh -d /srv/backups -n etc /etc
  backup.sh -d /srv/backups -n web -e '*.log' -e 'cache' /var/www /etc/nginx
  backup.sh -d /srv/backups -n web --keep-daily 7 --keep-weekly 8 --dry-run /var/www

Desde cron (todos los días a las 03:15):
  15 3 * * * /opt/sysadmin-toolkit/bin/backup.sh -q -d /srv/backups -n web --log /var/log/backup-web.log /var/www /etc/nginx
AYUDA
}

procesar_argumentos() {
  while (( $# > 0 )); do
    case $1 in
      -h|--help)
        mostrar_ayuda
        exit 0
        ;;
      --version)
        printf 'backup.sh (sysadmin-toolkit) %s\n' "$TOOLKIT_VERSION"
        exit 0
        ;;
      -d|--destino)  requerir_valor "$1" "${2-}"; DESTINO=$2; shift ;;
      -n|--nombre)   requerir_valor "$1" "${2-}"; PREFIJO=$2; shift ;;
      -e|--exclude)  requerir_valor "$1" "${2-}"; EXCLUSIONES+=("$2"); shift ;;
      --keep-daily)  requerir_valor "$1" "${2-}"; MANTENER_DIARIAS=$2; shift ;;
      --keep-weekly) requerir_valor "$1" "${2-}"; MANTENER_SEMANALES=$2; shift ;;
      --log)         requerir_valor "$1" "${2-}"; FICHERO_LOG=$2; shift ;;
      --dry-run)     SIMULACION=1 ;;
      -q|--quiet)    NIVEL_DETALLE=0 ;;
      -v|--verbose)  NIVEL_DETALLE=2 ;;
      --)
        shift
        ORIGENES+=("$@")
        break
        ;;
      -*) error_uso "Opción desconocida: $1" ;;
      *)  ORIGENES+=("$1") ;;
    esac
    shift
  done
}

validar_ajustes() {
  local origen
  local destino_real

  if [[ -z "$DESTINO" ]]; then
    error_uso "Falta el destino (-d DIR)."
  fi
  if (( ${#ORIGENES[@]} == 0 )); then
    error_uso "Indica al menos un directorio de origen."
  fi
  # El prefijo forma parte del nombre del fichero: nada de «/» ni espacios.
  if [[ ! "$PREFIJO" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    error_uso "--nombre: «${PREFIJO}» no es válido (letras, números, punto, guion y guion bajo)."
  fi
  if ! es_entero "$MANTENER_DIARIAS" || (( MANTENER_DIARIAS < 1 )); then
    error_uso "--keep-daily debe ser un entero mayor o igual que 1 (recibido «${MANTENER_DIARIAS}»)."
  fi
  if ! es_entero "$MANTENER_SEMANALES"; then
    error_uso "--keep-weekly debe ser un entero mayor o igual que 0 (recibido «${MANTENER_SEMANALES}»)."
  fi

  for origen in "${ORIGENES[@]}"; do
    if [[ ! -d "$origen" ]]; then
      error_uso "El origen no existe o no es un directorio: ${origen}"
    fi
    if [[ ! -r "$origen" || ! -x "$origen" ]]; then
      error_uso "Sin permiso de lectura en el origen: ${origen}"
    fi
  done

  if [[ -e "$DESTINO" && ! -d "$DESTINO" ]]; then
    error_uso "El destino existe pero no es un directorio: ${DESTINO}"
  fi
  # Trabajamos siempre con la ruta absoluta y sin «..» del destino.
  destino_real=$(realpath -m -- "$DESTINO")
  DESTINO=$destino_real

  if [[ -n "$FICHERO_LOG" ]]; then
    if (( SIMULACION == 1 )); then
      # En simulación no se escribe nada, tampoco el log.
      FICHERO_LOG=""
    elif [[ ! -d "$(dirname -- "$FICHERO_LOG")" ]]; then
      error_uso "--log: no existe el directorio de «${FICHERO_LOG}»."
    fi
  fi
}

# Se ejecuta siempre al salir (trap EXIT): detiene tar si seguía en marcha
# (nos han interrumpido con una señal) y borra la copia a medias si la hay.
limpiar() {
  if [[ -n "$PID_TAR" ]]; then
    kill "$PID_TAR" 2> /dev/null || true
    wait "$PID_TAR" 2> /dev/null || true
  fi
  if [[ -n "$FICHERO_ERRORES_TAR" ]]; then
    rm -f -- "$FICHERO_ERRORES_TAR"
  fi
  if [[ -n "$TEMPORAL_EN_CURSO" && -e "$TEMPORAL_EN_CURSO" ]]; then
    rm -f -- "$TEMPORAL_EN_CURSO"
    msg_aviso "Se ha borrado la copia incompleta ${TEMPORAL_EN_CURSO##*/}"
  fi
}

# ---------------------------------------------------------------------------
# Bloqueo
# ---------------------------------------------------------------------------
# flock sobre un fichero del destino. El bloqueo lo libera el kernel al
# terminar el proceso (aunque muera de forma brusca), así que no quedan
# bloqueos «huérfanos». El fichero no se borra al acabar: borrarlo abriría
# una carrera entre dos procesos que lo abren casi a la vez.
tomar_bloqueo() {
  local fichero_bloqueo="${DESTINO}/.${PREFIJO}.lock"
  # {FD_BLOQUEO} pide a bash un descriptor libre y guarda su número.
  exec {FD_BLOQUEO}>> "$fichero_bloqueo"
  if ! flock --nonblock "$FD_BLOQUEO"; then
    morir "Ya hay una copia en curso con destino ${DESTINO} y prefijo «${PREFIJO}» (bloqueo: ${fichero_bloqueo})." "$CODIGO_BLOQUEO"
  fi
  msg_debug "Bloqueo obtenido: ${fichero_bloqueo}"
}

# ---------------------------------------------------------------------------
# Nombres de copia
# ---------------------------------------------------------------------------
# ¿Es un nombre generado por este script con nuestro prefijo? Se comprueba
# el prefijo como texto (no dentro de la regex: un «.» en el prefijo sería un
# comodín) y el resto con una expresión regular anclada.
es_nombre_de_copia() {
  local nombre=$1
  local resto
  if [[ "$nombre" != "${PREFIJO}_"* ]]; then
    return 1
  fi
  resto=${nombre#"${PREFIJO}_"}
  [[ "$resto" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.tar\.gz$ ]]
}

# PREFIJO_2026-10-06_031500.tar.gz -> 2026-10-06
fecha_de_copia() {
  local resto=${1#"${PREFIJO}_"}
  printf '%s' "${resto:0:10}"
}

# Copias existentes de este prefijo, de la más nueva a la más antigua.
# El nombre lleva la fecha en formato ISO, así que el orden alfabético es
# también el orden cronológico.
listar_copias() {
  local -a encontradas=()
  local fichero
  local i
  if [[ -d "$DESTINO" ]]; then
    for fichero in "$DESTINO"/"$PREFIJO"_*.tar.gz; do
      # Sin coincidencias, el patrón queda tal cual: lo descartamos.
      if [[ -f "$fichero" ]] && es_nombre_de_copia "${fichero##*/}"; then
        encontradas+=("${fichero##*/}")
      fi
    done
  fi
  # El glob devuelve orden ascendente: lo recorremos al revés.
  for (( i = ${#encontradas[@]} - 1; i >= 0; i-- )); do
    printf '%s\n' "${encontradas[$i]}"
  done
}

# ---------------------------------------------------------------------------
# Retención
# ---------------------------------------------------------------------------
# Recibe los nombres de copia ordenados de más nueva a más antigua y rellena
# el array asociativo MOTIVO_CONSERVAR (nombre -> «diaria», «semanal» o
# «diaria+semanal»). Lo que no esté en él se borra.
declare -A MOTIVO_CONSERVAR=()

decidir_retencion() {
  local -A dias_vistos=()
  local -A semanas_vistas=()
  local dias=0
  local semanas=0
  local nombre
  local dia
  local semana

  for nombre in "$@"; do
    dia=$(fecha_de_copia "$nombre")
    # %G-W%V = año y semana ISO 8601 (la semana empieza en lunes).
    semana=$(date -d "$dia" '+%G-W%V')

    # Como vamos de más nueva a más antigua, la primera copia que vemos de
    # cada día (o semana) es la más reciente de ese día (o semana).
    if [[ -z "${dias_vistos[$dia]:-}" ]]; then
      dias_vistos[$dia]=1
      dias=$(( dias + 1 ))
      if (( dias <= MANTENER_DIARIAS )); then
        MOTIVO_CONSERVAR[$nombre]="diaria"
      fi
    fi

    if [[ -z "${semanas_vistas[$semana]:-}" ]]; then
      semanas_vistas[$semana]=1
      semanas=$(( semanas + 1 ))
      if (( semanas <= MANTENER_SEMANALES )); then
        if [[ -n "${MOTIVO_CONSERVAR[$nombre]:-}" ]]; then
          MOTIVO_CONSERVAR[$nombre]+="+semanal"
        else
          MOTIVO_CONSERVAR[$nombre]="semanal"
        fi
      fi
    fi
  done
}

# copia_nueva: nombre de la copia de esta ejecución (en simulación aún no
# existe en disco, pero se tiene en cuenta igual).
aplicar_retencion() {
  local copia_nueva=$1
  local -a copias=()
  local -a borrar=()
  local nombre

  mapfile -t copias < <(listar_copias)
  if (( SIMULACION == 1 )); then
    copias=("$copia_nueva" "${copias[@]}")
  fi

  decidir_retencion "${copias[@]}"

  for nombre in "${copias[@]}"; do
    if [[ -n "${MOTIVO_CONSERVAR[$nombre]:-}" ]]; then
      msg_debug "Se conserva ${nombre} (${MOTIVO_CONSERVAR[$nombre]})"
    else
      borrar+=("$nombre")
    fi
  done

  msg_info "Retención (diarias: ${MANTENER_DIARIAS}, semanales: ${MANTENER_SEMANALES}): $(plural "${#copias[@]}" copia copias), se conservan $(( ${#copias[@]} - ${#borrar[@]} )), se borran ${#borrar[@]}."

  for nombre in "${borrar[@]}"; do
    if (( SIMULACION == 1 )); then
      msg_info "[simulación] Se borraría ${nombre} (y su .sha256)"
    else
      rm -f -- "${DESTINO}/${nombre}" "${DESTINO}/${nombre}.sha256"
      msg_info "Borrada ${nombre}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Creación de la copia
# ---------------------------------------------------------------------------
# Construye en el array COMANDO_TAR la orden completa. Usar un array (y no un
# texto) evita problemas con espacios en rutas y patrones.
preparar_comando_tar() {
  local archivo=$1
  local origen
  local ruta_absoluta
  local patron

  COMANDO_TAR=(tar --create --gzip --file "$archivo")

  # Las exclusiones deben ir antes de las rutas: GNU tar solo las aplica a
  # los nombres que aparecen detrás.
  for patron in "${EXCLUSIONES[@]}"; do
    COMANDO_TAR+=("--exclude=${patron}")
  done

  # Si el destino está dentro de un origen (copiar /srv con destino
  # /srv/backups), lo excluimos para no meter las copias dentro de la copia.
  for origen in "${ORIGENES[@]}"; do
    ruta_absoluta=$(realpath -- "$origen")
    if [[ "$DESTINO/" == "$ruta_absoluta/"* || "$ruta_absoluta" == "/" ]]; then
      COMANDO_TAR+=("--exclude=${DESTINO#/}")
      msg_aviso "El destino está dentro de ${ruta_absoluta}: se excluye de la copia."
      break
    fi
  done

  # Rutas relativas a «/» (--directory /): el archivo guarda etc/nginx/...
  # y se puede restaurar en cualquier sitio con «tar -xzf ... -C DIR».
  COMANDO_TAR+=(--directory / --)
  for origen in "${ORIGENES[@]}"; do
    ruta_absoluta=$(realpath -- "$origen")
    if [[ "$ruta_absoluta" == "/" ]]; then
      COMANDO_TAR+=(".")
    else
      COMANDO_TAR+=("${ruta_absoluta#/}")
    fi
  done
}

# Tamaño total de los orígenes (solo informativo, en simulación y --verbose).
mostrar_tamano_origenes() {
  local origen
  local bytes
  for origen in "${ORIGENES[@]}"; do
    # du puede fallar en subdirectorios sin permiso y aun así dar un total.
    bytes=$(du -sb -- "$origen" 2>/dev/null | cut -f1 || true)
    if es_entero "$bytes"; then
      msg_info "Origen: $(realpath -- "$origen") ($(formatear_bytes "$bytes") sin comprimir)"
    else
      msg_info "Origen: $(realpath -- "$origen") (tamaño desconocido)"
    fi
  done
}

crear_copia() {
  local nombre=$1
  local archivo_final="${DESTINO}/${nombre}"
  local temporal="${archivo_final}.part"
  local errores_tar=""
  local codigo_tar=0

  if [[ -e "$archivo_final" ]]; then
    morir "Ya existe ${archivo_final}; espera un segundo y vuelve a intentarlo." 1
  fi

  TEMPORAL_EN_CURSO=$temporal
  preparar_comando_tar "$temporal"
  msg_debug "Orden: ${COMANDO_TAR[*]}"
  msg_info "Creando ${nombre}..."

  # tar se lanza en segundo plano y se espera con «wait». Mientras bash
  # espera a un comando en primer plano no atiende las señales hasta que el
  # comando termina; «wait», en cambio, se interrumpe y la trampa se ejecuta
  # en el momento (y limpiar() detiene tar). Así, un «kill» cancela la copia
  # al instante en lugar de esperar a que tar acabe.
  # Los errores de tar se guardan en un temporal para mostrarlos si fallan.
  # «|| codigo_tar=$?» recoge el código sin que set -e corte el script.
  FICHERO_ERRORES_TAR=$(mktemp)
  "${COMANDO_TAR[@]}" 2> "$FICHERO_ERRORES_TAR" &
  PID_TAR=$!
  wait "$PID_TAR" || codigo_tar=$?
  PID_TAR=""
  errores_tar=$(< "$FICHERO_ERRORES_TAR")

  # GNU tar: 0 = bien, 1 = algún fichero cambió mientras se leía (la copia es
  # válida, pero conviene saberlo), 2 o más = error grave.
  if (( codigo_tar == 1 )); then
    msg_aviso "Algunos ficheros cambiaron durante la copia: ${errores_tar//$'\n'/ | }"
  elif (( codigo_tar >= 2 )); then
    morir "tar ha fallado (código ${codigo_tar}): ${errores_tar//$'\n'/ | }" 1
  fi

  # Verificación: listar el contenido obliga a leer y descomprimir el archivo
  # entero, comprobando el CRC de gzip y la estructura de tar.
  if ! tar --list --gzip --file "$temporal" > /dev/null 2>&1; then
    morir "La verificación de ${nombre} ha fallado (tar --list). Se descarta la copia." 1
  fi
  msg_debug "Verificación con tar --list correcta"

  # Solo cuando la copia está completa y verificada recibe su nombre final:
  # una copia a medias nunca puede confundirse con una buena.
  mv -- "$temporal" "$archivo_final"
  TEMPORAL_EN_CURSO=""

  # Suma SHA-256 con el formato de sha256sum, para comprobarla después con:
  #   cd DESTINO && sha256sum -c NOMBRE.sha256
  ( cd -- "$DESTINO" && sha256sum -- "$nombre" > "${nombre}.sha256" )
  if ! ( cd -- "$DESTINO" && sha256sum --check --status -- "${nombre}.sha256" ); then
    morir "La suma SHA-256 de ${nombre} no coincide." 1
  fi

  msg_ok "Copia creada: ${archivo_final} ($(formatear_bytes "$(stat -c %s -- "$archivo_final")"))"
  msg_info "SHA-256: $(cut -d' ' -f1 "${archivo_final}.sha256")"
}

# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
main() {
  local nombre

  procesar_argumentos "$@"
  validar_ajustes

  # Las copias pueden contener datos sensibles (/etc/shadow, claves...):
  # todo lo que se crea queda legible solo para el propietario.
  umask 077

  nombre="${PREFIJO}_$(date '+%Y-%m-%d_%H%M%S').tar.gz"

  if (( SIMULACION == 1 )); then
    msg_info "Modo simulación (--dry-run): no se escribe ni se borra nada."
    mostrar_tamano_origenes
    preparar_comando_tar "${DESTINO}/${nombre}"
    if [[ ! -d "$DESTINO" ]]; then
      msg_info "[simulación] Se crearía el directorio ${DESTINO}"
    fi
    msg_info "[simulación] Se crearía ${DESTINO}/${nombre} y ${nombre}.sha256"
    msg_info "[simulación] Orden: ${COMANDO_TAR[*]}"
    aplicar_retencion "$nombre"
    msg_ok "Simulación terminada."
    exit 0
  fi

  if ! mkdir -p -- "$DESTINO"; then
    morir "No se puede crear el destino ${DESTINO}" 1
  fi
  if [[ ! -w "$DESTINO" ]]; then
    morir "Sin permiso de escritura en ${DESTINO}" 1
  fi

  trap limpiar EXIT
  # Al recibir Ctrl+C o una señal TERM salimos con el código habitual
  # (128 + número de señal); así también se ejecuta limpiar().
  trap 'exit 130' INT
  trap 'exit 143' TERM

  tomar_bloqueo
  if (( NIVEL_DETALLE >= 2 )); then
    mostrar_tamano_origenes
  fi
  SECONDS=0
  crear_copia "$nombre"
  aplicar_retencion "$nombre"
  msg_ok "Copia terminada en ${SECONDS} s."
}

main "$@"
