#!/usr/bin/env bash
#
# healthcheck.sh — Comprobación de salud de un servidor Linux.
#
# Revisa carga, memoria, swap, espacio e inodos de cada sistema de ficheros,
# servicios, puertos TCP en escucha, tiempo encendido, reinicio pendiente e
# intentos fallidos de acceso por SSH. Muestra un resumen en la terminal y,
# si se pide, genera un informe JSON y otro HTML autocontenido.
#
# Códigos de salida (convención de Nagios / Icinga):
#   0 OK · 1 WARNING · 2 CRITICAL · 3 UNKNOWN (error de uso o fallo inesperado)
#
# Autor: Miguel Ángel Alonso Valhondo — Licencia MIT

set -Eeuo pipefail

# Ruta real del script (aunque se llame mediante un enlace simbólico desde
# /usr/local/sbin), para encontrar la biblioteca común.
DIR_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/comun.sh
source "${DIR_SCRIPT}/../lib/comun.sh"
# shellcheck source=../lib/informe-html.sh
source "${DIR_SCRIPT}/../lib/informe-html.sh"

# Un error de uso o un fallo inesperado deben salir con 3 (UNKNOWN): si
# saliéramos con 1, Nagios lo mostraría como WARNING y despistaría.
CODIGO_USO=3
CODIGO_ERROR_INESPERADO=3
activar_trampa_errores

# ---------------------------------------------------------------------------
# Valores por defecto (se pueden cambiar con el fichero de configuración y,
# por encima de él, con las opciones de la línea de comandos).
# ---------------------------------------------------------------------------
DISCO_AVISO=80
DISCO_CRITICO=90
INODOS_AVISO=80
INODOS_CRITICO=90
MEMORIA_AVISO=85
MEMORIA_CRITICO=95
SWAP_AVISO=50
SWAP_CRITICO=80
CARGA_AVISO=100       # carga media de 5 min en % del número de núcleos
CARGA_CRITICO=200
SSH_AVISO=20          # líneas de fallo de SSH en el log de autenticación
SSH_CRITICO=100
SERVICIOS=""          # nombres separados por comas o espacios
PUERTOS_ESPERADOS=""  # puertos TCP que deben estar en escucha
EXCLUIR_MONTAJES=""   # patrones (glob) de puntos de montaje a ignorar
FICHERO_AUTH=""       # vacío = /var/log/auth.log o /var/log/secure
FICHERO_REINICIO="/var/run/reboot-required"
ETIQUETA=""           # nombre a mostrar en el informe (por defecto, el host)

FICHERO_CONFIG=""
SALIDA_JSON=""
SALIDA_HTML=""
MODO_NAGIOS=0

# Secciones del informe, en el orden en que se muestran.
readonly SECCIONES=(recursos almacenamiento servicios red sistema)
declare -A TITULO_SECCION=(
  [recursos]="Recursos"
  [almacenamiento]="Almacenamiento"
  [servicios]="Servicios"
  [red]="Red"
  [sistema]="Sistema y seguridad"
)

# Texto que ve una persona para cada estado (el JSON usa los nombres de Nagios).
declare -A TEXTO_ESTADO=(
  [OK]="OK"
  [WARNING]="Aviso"
  [CRITICAL]="Crítico"
  [UNKNOWN]="Desconocido"
  [INFO]="Info"
)

# Resultados: un elemento por comprobación, en arrays paralelos (el índice i
# de cada array corresponde a la misma comprobación).
RES_SECCION=()
RES_NOMBRE=()
RES_ESTADO=()
RES_VALOR=()
RES_UMBRAL=()
RES_DETALLE=()
RES_PORCENTAJE=()   # vacío si la comprobación no tiene barra de uso
RES_AVISO=()
RES_CRITICO=()

mostrar_ayuda() {
  cat <<'AYUDA'
Uso: healthcheck.sh [opciones]

Comprueba el estado de salud del servidor y termina con un código de salida
compatible con Nagios/Icinga: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.

Comprobaciones:
  · carga media (5 min) en relación con el número de núcleos
  · uso de memoria (según MemAvailable) y de swap
  · espacio e inodos de cada sistema de ficheros local (se ignoran tmpfs,
    overlay, squashfs... salvo la raíz «/», que se revisa siempre)
  · servicios: systemctl is-active si hay systemd; si no, pgrep -x
  · puertos TCP en escucha (ss -ltn; si no existe, /proc/net/tcp)
  · tiempo encendido y reinicio pendiente (/var/run/reboot-required)
  · intentos fallidos de SSH, si el log de autenticación es legible

Umbrales (porcentajes enteros; «aviso» debe ser menor o igual que «crítico»):
  --disk-warn N  --disk-crit N     espacio en disco        (por defecto 80 / 90)
  --inode-warn N --inode-crit N    inodos                  (por defecto 80 / 90)
  --mem-warn N   --mem-crit N      memoria                 (por defecto 85 / 95)
  --swap-warn N  --swap-crit N     swap                    (por defecto 50 / 80)
  --load-warn N  --load-crit N     carga en % de núcleos   (por defecto 100 / 200)
  --ssh-warn N   --ssh-crit N      fallos de SSH en el log (por defecto 20 / 100)

Qué revisar:
  --servicios LISTA          servicios separados por comas (ej. "sshd,cron,nginx")
  --puertos-esperados LISTA  puertos TCP que deben estar en escucha (ej. "22,443")
  --excluir-montaje PATRÓN   ignora los montajes que encajen (ej. '/snap/*');
                             se puede repetir
  --auth-log FICHERO         log de autenticación a analizar
  --fichero-reinicio RUTA    marca de reinicio pendiente
                             (por defecto /var/run/reboot-required)

Salidas:
  --json FICHERO             guarda el resultado en JSON
  --html FICHERO             guarda un informe HTML autocontenido
  --etiqueta TEXTO           nombre a mostrar en el informe (por defecto, el host)
  --nagios                   imprime una sola línea con datos de rendimiento,
                             para usarlo como plugin de Nagios/Icinga (NRPE)

Generales:
  -c, --config FICHERO       carga umbrales y opciones de un fichero (ver
                             ejemplos/healthcheck.conf); las opciones de la
                             línea de comandos tienen prioridad
  -q, --quiet                sin salida en pantalla (solo código de salida y ficheros)
  -v, --verbose              muestra detalles de cada comprobación
  -h, --help                 muestra esta ayuda
      --version              muestra la versión

Ejemplos:
  healthcheck.sh
  healthcheck.sh --servicios "sshd,cron" --disk-warn 75 --disk-crit 90
  healthcheck.sh -c /etc/healthcheck.conf --quiet --html /var/www/estado/index.html
  healthcheck.sh --nagios --servicios nginx --puertos-esperados 80,443

Desde cron (avisa por correo solo si algo no está OK):
  */15 * * * * /opt/sysadmin-toolkit/bin/healthcheck.sh -q -c /etc/healthcheck.conf || echo "healthcheck: código $?"
AYUDA
}

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

# Primera pasada por los argumentos: solo busca -c/--config. El fichero se
# carga antes que el resto de opciones para que estas tengan prioridad.
buscar_fichero_config() {
  while (( $# > 0 )); do
    case $1 in
      -c|--config)
        requerir_valor "$1" "${2-}"
        FICHERO_CONFIG=$2
        return 0
        ;;
      *) ;;   # el resto de opciones se procesan después
    esac
    shift
  done
}

# Lee un fichero CLAVE=valor. No se usa «source»: el fichero se analiza línea
# a línea y solo se aceptan claves conocidas, así un fichero de configuración
# nunca puede ejecutar código (por ejemplo «ETIQUETA=$(rm -rf /)»).
cargar_configuracion() {
  local fichero=$1
  local linea
  local numero=0
  local clave
  local resto
  local valor

  if [[ ! -f "$fichero" || ! -r "$fichero" ]]; then
    error_uso "No se puede leer el fichero de configuración: ${fichero}"
  fi
  msg_debug "Cargando configuración de ${fichero}"

  # «|| [[ -n $linea ]]» procesa también la última línea si no acaba en \n.
  while IFS= read -r linea || [[ -n "$linea" ]]; do
    numero=$(( numero + 1 ))
    linea=${linea%$'\r'}                       # ficheros editados en Windows

    # Líneas vacías o comentarios.
    if [[ "$linea" =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    if [[ ! "$linea" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      error_uso "${fichero}:${numero}: línea no válida (se espera CLAVE=valor)."
    fi
    clave=${BASH_REMATCH[1]}
    resto=${BASH_REMATCH[2]}

    # El valor puede ir entre comillas dobles, simples o sin comillas (sin
    # espacios). Detrás puede haber un comentario.
    if [[ "$resto" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
      valor=${BASH_REMATCH[1]}
    elif [[ "$resto" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      valor=${BASH_REMATCH[1]}
    elif [[ "$resto" =~ ^([^[:space:]#\"\']*)[[:space:]]*(#.*)?$ ]]; then
      valor=${BASH_REMATCH[1]}
    else
      error_uso "${fichero}:${numero}: valor mal formado para ${clave} (usa comillas si lleva espacios)."
    fi

    case $clave in
      DISCO_AVISO)       DISCO_AVISO=$valor ;;
      DISCO_CRITICO)     DISCO_CRITICO=$valor ;;
      INODOS_AVISO)      INODOS_AVISO=$valor ;;
      INODOS_CRITICO)    INODOS_CRITICO=$valor ;;
      MEMORIA_AVISO)     MEMORIA_AVISO=$valor ;;
      MEMORIA_CRITICO)   MEMORIA_CRITICO=$valor ;;
      SWAP_AVISO)        SWAP_AVISO=$valor ;;
      SWAP_CRITICO)      SWAP_CRITICO=$valor ;;
      CARGA_AVISO)       CARGA_AVISO=$valor ;;
      CARGA_CRITICO)     CARGA_CRITICO=$valor ;;
      SSH_AVISO)         SSH_AVISO=$valor ;;
      SSH_CRITICO)       SSH_CRITICO=$valor ;;
      SERVICIOS)         SERVICIOS=$valor ;;
      PUERTOS_ESPERADOS) PUERTOS_ESPERADOS=$valor ;;
      EXCLUIR_MONTAJES)  EXCLUIR_MONTAJES=$valor ;;
      FICHERO_AUTH)      FICHERO_AUTH=$valor ;;
      FICHERO_REINICIO)  FICHERO_REINICIO=$valor ;;
      ETIQUETA)          ETIQUETA=$valor ;;
      *) error_uso "${fichero}:${numero}: clave desconocida «${clave}»." ;;
    esac
  done < "$fichero"
}

procesar_argumentos() {
  while (( $# > 0 )); do
    case $1 in
      -h|--help)
        mostrar_ayuda
        exit 0
        ;;
      --version)
        printf 'healthcheck.sh (sysadmin-toolkit) %s\n' "$TOOLKIT_VERSION"
        exit 0
        ;;
      -q|--quiet)   NIVEL_DETALLE=0 ;;
      -v|--verbose) NIVEL_DETALLE=2 ;;
      --nagios)     MODO_NAGIOS=1 ;;
      -c|--config)
        # Ya se cargó en la primera pasada; aquí solo se salta su valor.
        requerir_valor "$1" "${2-}"
        shift
        ;;
      --disk-warn)   requerir_valor "$1" "${2-}"; DISCO_AVISO=$2; shift ;;
      --disk-crit)   requerir_valor "$1" "${2-}"; DISCO_CRITICO=$2; shift ;;
      --inode-warn)  requerir_valor "$1" "${2-}"; INODOS_AVISO=$2; shift ;;
      --inode-crit)  requerir_valor "$1" "${2-}"; INODOS_CRITICO=$2; shift ;;
      --mem-warn)    requerir_valor "$1" "${2-}"; MEMORIA_AVISO=$2; shift ;;
      --mem-crit)    requerir_valor "$1" "${2-}"; MEMORIA_CRITICO=$2; shift ;;
      --swap-warn)   requerir_valor "$1" "${2-}"; SWAP_AVISO=$2; shift ;;
      --swap-crit)   requerir_valor "$1" "${2-}"; SWAP_CRITICO=$2; shift ;;
      --load-warn)   requerir_valor "$1" "${2-}"; CARGA_AVISO=$2; shift ;;
      --load-crit)   requerir_valor "$1" "${2-}"; CARGA_CRITICO=$2; shift ;;
      --ssh-warn)    requerir_valor "$1" "${2-}"; SSH_AVISO=$2; shift ;;
      --ssh-crit)    requerir_valor "$1" "${2-}"; SSH_CRITICO=$2; shift ;;
      --servicios)   requerir_valor "$1" "${2-}"; SERVICIOS=$2; shift ;;
      --puertos-esperados) requerir_valor "$1" "${2-}"; PUERTOS_ESPERADOS=$2; shift ;;
      --excluir-montaje)   requerir_valor "$1" "${2-}"; EXCLUIR_MONTAJES+=" $2"; shift ;;
      --auth-log)          requerir_valor "$1" "${2-}"; FICHERO_AUTH=$2; shift ;;
      --fichero-reinicio)  requerir_valor "$1" "${2-}"; FICHERO_REINICIO=$2; shift ;;
      --etiqueta)    requerir_valor "$1" "${2-}"; ETIQUETA=$2; shift ;;
      --json)        requerir_valor "$1" "${2-}"; SALIDA_JSON=$2; shift ;;
      --html)        requerir_valor "$1" "${2-}"; SALIDA_HTML=$2; shift ;;
      -*) error_uso "Opción desconocida: $1" ;;
      *)  error_uso "Argumento inesperado: $1" ;;
    esac
    shift
  done
}

# Comprueba un par aviso/crítico: enteros, dentro del máximo y aviso <= crítico.
validar_umbrales() {
  local nombre=$1
  local aviso=$2
  local critico=$3
  local maximo=$4
  if ! es_entero "$aviso" || ! es_entero "$critico"; then
    error_uso "${nombre}: los umbrales deben ser enteros sin signo (recibido «${aviso}» y «${critico}»)."
  fi
  if (( aviso > maximo || critico > maximo )); then
    error_uso "${nombre}: los umbrales no pueden superar ${maximo}."
  fi
  if (( aviso > critico )); then
    error_uso "${nombre}: el umbral de aviso (${aviso}) no puede ser mayor que el crítico (${critico})."
  fi
}

# Comprueba que se puede escribir un fichero de salida (su directorio existe).
validar_salida() {
  local opcion=$1
  local fichero=$2
  local directorio
  if [[ -z "$fichero" ]]; then
    return 0
  fi
  directorio=$(dirname -- "$fichero")
  if [[ ! -d "$directorio" || ! -w "$directorio" ]]; then
    error_uso "${opcion}: no se puede escribir en el directorio «${directorio}»."
  fi
}

validar_ajustes() {
  local servicio
  local puerto
  local -a lista

  validar_umbrales "--disk-warn/--disk-crit"   "$DISCO_AVISO"   "$DISCO_CRITICO"   100
  validar_umbrales "--inode-warn/--inode-crit" "$INODOS_AVISO"  "$INODOS_CRITICO"  100
  validar_umbrales "--mem-warn/--mem-crit"     "$MEMORIA_AVISO" "$MEMORIA_CRITICO" 100
  validar_umbrales "--swap-warn/--swap-crit"   "$SWAP_AVISO"    "$SWAP_CRITICO"    100
  validar_umbrales "--load-warn/--load-crit"   "$CARGA_AVISO"   "$CARGA_CRITICO"   10000
  validar_umbrales "--ssh-warn/--ssh-crit"     "$SSH_AVISO"     "$SSH_CRITICO"     1000000

  # Nombres de servicio: letras, números y los símbolos que admite systemd.
  IFS=', ' read -r -a lista <<< "$SERVICIOS"
  for servicio in "${lista[@]}"; do
    if [[ ! "$servicio" =~ ^[A-Za-z0-9@._:+-]+$ ]]; then
      error_uso "--servicios: nombre de servicio no válido: «${servicio}»."
    fi
  done

  IFS=', ' read -r -a lista <<< "$PUERTOS_ESPERADOS"
  for puerto in "${lista[@]}"; do
    if ! es_entero "$puerto" || (( puerto < 1 || puerto > 65535 )); then
      error_uso "--puertos-esperados: puerto no válido: «${puerto}» (1-65535)."
    fi
  done

  if (( ${#ETIQUETA} > 80 )); then
    error_uso "--etiqueta: máximo 80 caracteres."
  fi

  validar_salida "--json" "$SALIDA_JSON"
  validar_salida "--html" "$SALIDA_HTML"
}

# ---------------------------------------------------------------------------
# Registro de resultados
# ---------------------------------------------------------------------------

# registrar SECCIÓN NOMBRE ESTADO VALOR UMBRAL DETALLE [PORCENTAJE AVISO CRÍTICO]
# ESTADO es OK, WARNING, CRITICAL, UNKNOWN o INFO (informativo, no cuenta
# para el estado global). Los tres últimos datos solo se usan para dibujar la
# barra de uso en el informe HTML.
registrar() {
  RES_SECCION+=("$1")
  RES_NOMBRE+=("$2")
  RES_ESTADO+=("$3")
  RES_VALOR+=("$4")
  RES_UMBRAL+=("$5")
  RES_DETALLE+=("$6")
  RES_PORCENTAJE+=("${7-}")
  RES_AVISO+=("${8-}")
  RES_CRITICO+=("${9-}")
  msg_debug "$2: $3 ($4)"
}

# Devuelve el estado de un valor frente a sus umbrales (mayor o igual = salta).
evaluar_umbral() {
  local valor=$1
  local aviso=$2
  local critico=$3
  if (( valor >= critico )); then
    echo CRITICAL
  elif (( valor >= aviso )); then
    echo WARNING
  else
    echo OK
  fi
}

# Texto de umbral común a los porcentajes.
texto_umbral() {
  printf 'aviso ≥ %s%% · crítico ≥ %s%%' "$1" "$2"
}

# ---------------------------------------------------------------------------
# Datos generales del sistema
# ---------------------------------------------------------------------------
recoger_datos_sistema() {
  local linea

  HOST_NOMBRE=$(uname -n)
  KERNEL=$(uname -r)
  NUCLEOS=$(nproc 2>/dev/null || echo 1)
  FECHA_LEGIBLE=$(date '+%Y-%m-%d %H:%M:%S %Z')
  FECHA_ISO=$(date '+%Y-%m-%dT%H:%M:%S%:z')

  # Nombre de la distribución. /etc/os-release se lee, no se ejecuta.
  SO_NOMBRE="Linux"
  if [[ -r /etc/os-release ]]; then
    while IFS= read -r linea; do
      if [[ "$linea" =~ ^PRETTY_NAME=\"?([^\"]*)\"?$ ]]; then
        SO_NOMBRE=${BASH_REMATCH[1]}
      fi
    done < /etc/os-release
  fi

  if [[ -z "$ETIQUETA" ]]; then
    ETIQUETA=$HOST_NOMBRE
  fi
}

# ---------------------------------------------------------------------------
# Comprobaciones
# ---------------------------------------------------------------------------

comprobar_carga() {
  local carga1
  local carga5
  local carga15
  local centesimas
  local porcentaje
  local barra
  local estado

  if [[ ! -r /proc/loadavg ]]; then
    registrar recursos "Carga media (5 min)" UNKNOWN "no disponible" "" "No se puede leer /proc/loadavg."
    return 0
  fi
  read -r carga1 carga5 carga15 _ < /proc/loadavg

  # /proc/loadavg trae siempre dos decimales: «0.48» -> 48 centésimas.
  # 10# fuerza base 10 («008» daría error al leerse como octal).
  centesimas=$(( 10#${carga5/./} ))
  porcentaje=$(( centesimas / NUCLEOS ))
  estado=$(evaluar_umbral "$porcentaje" "$CARGA_AVISO" "$CARGA_CRITICO")

  # La barra va de 0 a 100 % de los núcleos; si se pasa, se dibuja llena.
  barra=$porcentaje
  if (( barra > 100 )); then
    barra=100
  fi

  registrar recursos "Carga media (5 min)" "$estado" \
    "${carga5} · ${porcentaje}% de ${NUCLEOS} núcleos" \
    "$(texto_umbral "$CARGA_AVISO" "$CARGA_CRITICO")" \
    "1 / 5 / 15 min: ${carga1} / ${carga5} / ${carga15}" \
    "$barra" "$CARGA_AVISO" "$CARGA_CRITICO"
}

comprobar_memoria() {
  local clave
  local valor
  local total_kb=0
  local disponible_kb=0
  local swap_total_kb=0
  local swap_libre_kb=0
  local usado_kb
  local porcentaje
  local estado

  if [[ ! -r /proc/meminfo ]]; then
    registrar recursos "Memoria" UNKNOWN "no disponible" "" "No se puede leer /proc/meminfo."
    return 0
  fi

  # Formato de /proc/meminfo: «MemTotal:  8223864 kB»
  while read -r clave valor _; do
    case $clave in
      MemTotal:)     total_kb=$valor ;;
      MemAvailable:) disponible_kb=$valor ;;
      SwapTotal:)    swap_total_kb=$valor ;;
      SwapFree:)     swap_libre_kb=$valor ;;
      *) ;;          # el resto de líneas no interesan
    esac
  done < /proc/meminfo

  if (( total_kb == 0 || disponible_kb == 0 )); then
    registrar recursos "Memoria" UNKNOWN "no disponible" "" "El kernel no informa de MemAvailable."
  else
    # Memoria usada = total - disponible. MemAvailable ya descuenta la caché
    # que el kernel puede liberar, así que no da falsas alarmas por la caché.
    usado_kb=$(( total_kb - disponible_kb ))
    porcentaje=$(( usado_kb * 100 / total_kb ))
    estado=$(evaluar_umbral "$porcentaje" "$MEMORIA_AVISO" "$MEMORIA_CRITICO")
    registrar recursos "Memoria" "$estado" \
      "${porcentaje}% · $(formatear_bytes $(( usado_kb * 1024 ))) de $(formatear_bytes $(( total_kb * 1024 )))" \
      "$(texto_umbral "$MEMORIA_AVISO" "$MEMORIA_CRITICO")" \
      "Disponible: $(formatear_bytes $(( disponible_kb * 1024 ))) (MemAvailable, incluye caché recuperable)" \
      "$porcentaje" "$MEMORIA_AVISO" "$MEMORIA_CRITICO"
  fi

  if (( swap_total_kb == 0 )); then
    registrar recursos "Swap" INFO "sin swap" "" "No hay espacio de intercambio configurado."
  else
    usado_kb=$(( swap_total_kb - swap_libre_kb ))
    porcentaje=$(( usado_kb * 100 / swap_total_kb ))
    estado=$(evaluar_umbral "$porcentaje" "$SWAP_AVISO" "$SWAP_CRITICO")
    registrar recursos "Swap" "$estado" \
      "${porcentaje}% · $(formatear_bytes $(( usado_kb * 1024 ))) de $(formatear_bytes $(( swap_total_kb * 1024 )))" \
      "$(texto_umbral "$SWAP_AVISO" "$SWAP_CRITICO")" "" \
      "$porcentaje" "$SWAP_AVISO" "$SWAP_CRITICO"
  fi
}

# Tipos de sistema de ficheros que no son discos reales: memoria, capas de
# contenedores, imágenes de solo lectura, pseudo-sistemas y montajes FUSE.
es_tipo_ignorado() {
  case $1 in
    tmpfs|devtmpfs|ramfs|overlay|squashfs|iso9660|udf|nsfs|efivarfs) return 0 ;;
    proc|sysfs|cgroup|cgroup2|autofs|fuse.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ¿El punto de montaje encaja con algún patrón de --excluir-montaje?
es_montaje_excluido() {
  local montaje=$1
  local -a patrones
  local patron
  # read -a separa por comas/espacios sin expandir comodines (un «for» sobre
  # la variable sin comillas expandiría '/snap/*' contra el disco).
  IFS=', ' read -r -a patrones <<< "$EXCLUIR_MONTAJES"
  for patron in "${patrones[@]}"; do
    # El patrón va sin comillas a propósito: así «case» lo trata como glob
    # ('/snap/*' encaja con /snap/core/123), que es justo lo que queremos.
    # shellcheck disable=SC2254
    case $montaje in
      $patron) return 0 ;;
      *) ;;
    esac
  done
  return 1
}

comprobar_discos() {
  local origen
  local tipo
  local total
  local usado
  local libre
  local pcent
  local itotal
  local iusado
  local ipcent
  local montaje
  local estado
  local revisados=0

  # --local: solo sistemas locales; un NFS caído podría dejar df bloqueado.
  # --output: columnas fijas, espacio e inodos en una sola llamada.
  # Si df falla con algún montaje concreto sigue mostrando el resto, por eso
  # se lee mediante sustitución de proceso y se ignora su código de salida.
  while read -r origen tipo total usado libre pcent itotal iusado ipcent montaje; do
    # La raíz «/» se revisa siempre, aunque sea overlay (contenedores): así
    # nunca nos quedamos sin ningún disco que vigilar.
    if [[ "$montaje" != "/" ]] && es_tipo_ignorado "$tipo"; then
      msg_debug "Se ignora ${montaje} (tipo ${tipo})"
      continue
    fi
    if es_montaje_excluido "$montaje"; then
      msg_debug "Se ignora ${montaje} (excluido por patrón)"
      continue
    fi
    revisados=$(( revisados + 1 ))

    pcent=${pcent%\%}
    if es_entero "$pcent"; then
      estado=$(evaluar_umbral "$pcent" "$DISCO_AVISO" "$DISCO_CRITICO")
      registrar almacenamiento "Disco ${montaje}" "$estado" \
        "${pcent}% · $(formatear_bytes "$usado") de $(formatear_bytes "$total")" \
        "$(texto_umbral "$DISCO_AVISO" "$DISCO_CRITICO")" \
        "${origen} (${tipo}) · libre: $(formatear_bytes "$libre")" \
        "$pcent" "$DISCO_AVISO" "$DISCO_CRITICO"
    fi

    # Algunos sistemas (btrfs, vfat) no tienen inodos fijos: df muestra «-».
    ipcent=${ipcent%\%}
    if es_entero "$ipcent" && es_entero "$itotal" && (( itotal > 0 )); then
      estado=$(evaluar_umbral "$ipcent" "$INODOS_AVISO" "$INODOS_CRITICO")
      registrar almacenamiento "Inodos ${montaje}" "$estado" \
        "${ipcent}% · $(separar_miles "$iusado") de $(separar_miles "$itotal")" \
        "$(texto_umbral "$INODOS_AVISO" "$INODOS_CRITICO")" \
        "${origen} · libres: $(separar_miles $(( itotal - iusado )))" \
        "$ipcent" "$INODOS_AVISO" "$INODOS_CRITICO"
    fi
  done < <(df --local --block-size=1 \
             --output=source,fstype,size,used,avail,pcent,itotal,iused,ipcent,target \
             2>/dev/null | tail -n +2)

  if (( revisados == 0 )); then
    registrar almacenamiento "Discos" UNKNOWN "sin datos" "" \
      "df no ha devuelto ningún sistema de ficheros que revisar."
  fi
}

comprobar_servicios() {
  local -a lista
  local servicio
  local metodo
  local estado_unidad
  local procesos

  IFS=', ' read -r -a lista <<< "$SERVICIOS"
  if (( ${#lista[@]} == 0 )); then
    registrar servicios "Servicios" INFO "ninguno configurado" "" \
      "Indica cuáles vigilar con --servicios o SERVICIOS= en el fichero de configuración."
    return 0
  fi

  # /run/systemd/system solo existe si systemd es el sistema de arranque (es
  # la misma comprobación que hace sd_booted()). En contenedores sin systemd
  # se usa pgrep, que busca el proceso por su nombre exacto.
  if [[ -d /run/systemd/system ]] && command -v systemctl > /dev/null 2>&1; then
    metodo=systemd
  elif command -v pgrep > /dev/null 2>&1; then
    metodo=pgrep
  else
    metodo=ninguno
  fi
  msg_debug "Método para comprobar servicios: ${metodo}"

  for servicio in "${lista[@]}"; do
    case $metodo in
      systemd)
        # is-active imprime el estado (active, inactive, failed...). Devuelve
        # distinto de 0 si no está activo: «|| true» evita que set -e corte.
        estado_unidad=$(systemctl is-active -- "$servicio" 2>/dev/null || true)
        if [[ "$estado_unidad" == "active" ]]; then
          registrar servicios "Servicio ${servicio}" OK "activo" "debe estar activo" "systemctl is-active"
        else
          registrar servicios "Servicio ${servicio}" CRITICAL "${estado_unidad:-desconocido}" \
            "debe estar activo" "systemctl is-active ${servicio} → ${estado_unidad:-sin respuesta}"
        fi
        ;;
      pgrep)
        # -c cuenta procesos; -x exige el nombre exacto. pgrep devuelve 1 si
        # no encuentra ninguno (y aun así imprime 0).
        procesos=$(pgrep -c -x -- "$servicio" || true)
        if (( procesos > 0 )); then
          registrar servicios "Servicio ${servicio}" OK "en ejecución · $(plural "$procesos" proceso procesos)" \
            "debe estar en ejecución" "pgrep -x ${servicio} (sin systemd)"
        else
          registrar servicios "Servicio ${servicio}" CRITICAL "no está en ejecución" \
            "debe estar en ejecución" "pgrep -x ${servicio} no encuentra ningún proceso (sin systemd)"
        fi
        ;;
      *)
        registrar servicios "Servicio ${servicio}" UNKNOWN "no comprobable" "" \
          "No hay systemctl (con systemd) ni pgrep."
        ;;
    esac
  done
}

# Puerto -> direcciones en las que escucha (ej. [22]="0.0.0.0, [::]").
declare -A PUERTOS_ESCUCHA=()
FUENTE_PUERTOS=""

anotar_puerto() {
  local puerto=$1
  local direccion=$2
  local actuales=${PUERTOS_ESCUCHA[$puerto]:-}
  if [[ -z "$actuales" ]]; then
    PUERTOS_ESCUCHA[$puerto]=$direccion
  elif [[ ", ${actuales}, " != *", ${direccion}, "* ]]; then
    PUERTOS_ESCUCHA[$puerto]="${actuales}, ${direccion}"
  fi
}

# /proc/net/tcp guarda la IPv4 en hexadecimal y al revés (little-endian):
# 0100007F -> 7F.00.00.01 -> 127.0.0.1
hex_a_ipv4() {
  local h=$1
  printf '%d.%d.%d.%d' "0x${h:6:2}" "0x${h:4:2}" "0x${h:2:2}" "0x${h:0:2}"
}

# Para IPv6 solo se resumen los casos habituales en servidores.
hex_a_ipv6() {
  case $1 in
    00000000000000000000000000000000) printf '[::]' ;;
    00000000000000000000000001000000) printf '[::1]' ;;
    0000000000000000FFFF0000*)        printf '[::ffff:%s]' "$(hex_a_ipv4 "${1:24:8}")" ;;
    *)                                printf '[IPv6]' ;;
  esac
}

# Lee /proc/net/tcp o /proc/net/tcp6. Columnas: sl local_address
# rem_address st ... ; el estado 0A es LISTEN.
leer_proc_net_tcp() {
  local fichero=$1
  local familia=$2
  local local_hex
  local estado
  local direccion
  while read -r _ local_hex _ estado _; do
    if [[ "$estado" != "0A" ]]; then
      continue
    fi
    if [[ "$familia" == "4" ]]; then
      direccion=$(hex_a_ipv4 "${local_hex%%:*}")
    else
      direccion=$(hex_a_ipv6 "${local_hex%%:*}")
    fi
    anotar_puerto "$(( 16#${local_hex##*:} ))" "$direccion"
  done < <(tail -n +2 "$fichero")
}

recoger_puertos_escucha() {
  local salida
  local local_dir

  # Primera opción: ss (iproute2). -H sin cabecera, -l en escucha, -t TCP,
  # -n sin resolver nombres.
  if command -v ss > /dev/null 2>&1 && salida=$(ss -Hltn 2>/dev/null); then
    FUENTE_PUERTOS="ss -ltn"
    while read -r _ _ _ local_dir _; do
      if [[ -n "$local_dir" ]]; then
        # «0.0.0.0:22», «[::]:22», «127.0.0.53%lo:53»: el puerto va tras el último «:».
        anotar_puerto "${local_dir##*:}" "${local_dir%:*}"
      fi
    done <<< "$salida"
    return 0
  fi

  # Alternativa sin dependencias: leer directamente las tablas del kernel.
  if [[ -r /proc/net/tcp ]]; then
    FUENTE_PUERTOS="/proc/net/tcp (ss no está disponible)"
    leer_proc_net_tcp /proc/net/tcp 4
    if [[ -r /proc/net/tcp6 ]]; then
      leer_proc_net_tcp /proc/net/tcp6 6
    fi
    return 0
  fi
  return 1
}

comprobar_puertos() {
  local -a ordenados
  local -a esperados
  local puerto
  local texto_puertos=""
  local detalle=""
  local -A por_direccion=()
  local -a direcciones
  local -a direcciones_ordenadas
  local direccion

  if ! recoger_puertos_escucha; then
    registrar red "Puertos TCP en escucha" UNKNOWN "no disponible" "" \
      "No hay ss ni /proc/net/tcp legible."
    return 0
  fi
  msg_debug "Fuente de puertos: ${FUENTE_PUERTOS}"

  mapfile -t ordenados < <(printf '%s\n' "${!PUERTOS_ESCUCHA[@]}" | sort -n)
  for puerto in "${ordenados[@]}"; do
    if [[ -z "$puerto" ]]; then
      continue
    fi
    texto_puertos+="${texto_puertos:+, }${puerto}"
    # Agrupamos por dirección: se ve de un vistazo qué está expuesto en todas
    # las interfaces (0.0.0.0, [::]) y qué solo en local (127.0.0.1).
    IFS=',' read -r -a direcciones <<< "${PUERTOS_ESCUCHA[$puerto]// /}"
    for direccion in "${direcciones[@]}"; do
      por_direccion[$direccion]+="${por_direccion[$direccion]:+, }${puerto}"
    done
  done

  if (( ${#por_direccion[@]} > 0 )); then
    mapfile -t direcciones_ordenadas < <(printf '%s\n' "${!por_direccion[@]}" | sort)
    for direccion in "${direcciones_ordenadas[@]}"; do
      detalle+="${detalle:+ · }${direccion} → ${por_direccion[$direccion]}"
    done
  fi

  registrar red "Puertos TCP en escucha" INFO \
    "$(plural "${#PUERTOS_ESCUCHA[@]}" puerto puertos): ${texto_puertos:-ninguno}" "" \
    "${detalle:-Ningún puerto en escucha.} · Fuente: ${FUENTE_PUERTOS}"

  IFS=', ' read -r -a esperados <<< "$PUERTOS_ESPERADOS"
  for puerto in "${esperados[@]}"; do
    if [[ -n "${PUERTOS_ESCUCHA[$puerto]:-}" ]]; then
      registrar red "Puerto ${puerto}/tcp" OK "en escucha" "debe estar en escucha" \
        "Direcciones: ${PUERTOS_ESCUCHA[$puerto]}"
    else
      registrar red "Puerto ${puerto}/tcp" CRITICAL "no está en escucha" "debe estar en escucha" \
        "Ningún proceso escucha en el puerto ${puerto}/tcp."
    fi
  done
}

comprobar_tiempo_encendido() {
  local segundos
  local arranque
  if [[ ! -r /proc/uptime ]]; then
    registrar sistema "Tiempo encendido" UNKNOWN "no disponible" "" "No se puede leer /proc/uptime."
    return 0
  fi
  read -r segundos _ < /proc/uptime
  segundos=${segundos%.*}                     # nos quedamos con la parte entera
  arranque=$(date -d "@$(( $(date +%s) - segundos ))" '+%Y-%m-%d %H:%M')
  TIEMPO_ENCENDIDO=$(formatear_duracion "$segundos")
  registrar sistema "Tiempo encendido" INFO "$TIEMPO_ENCENDIDO" "" "Último arranque: ${arranque}"
}

comprobar_reinicio_pendiente() {
  local paquetes=""
  # Debian/Ubuntu crean esta marca al instalar un kernel o una librería básica.
  if [[ -e "$FICHERO_REINICIO" ]]; then
    if [[ -r "${FICHERO_REINICIO}.pkgs" ]]; then
      paquetes=$(sort -u "${FICHERO_REINICIO}.pkgs" | tr '\n' ' ')
    fi
    registrar sistema "Reinicio pendiente" WARNING "sí" "sin reinicio pendiente" \
      "Existe ${FICHERO_REINICIO}.${paquetes:+ Paquetes: ${paquetes}}"
    return 0
  fi
  # RHEL / Rocky / Alma: needs-restarting -r devuelve 1 si hace falta reiniciar.
  if command -v needs-restarting > /dev/null 2>&1; then
    if ! timeout 30 needs-restarting -r > /dev/null 2>&1; then
      registrar sistema "Reinicio pendiente" WARNING "sí" "sin reinicio pendiente" \
        "needs-restarting -r indica que hay que reiniciar."
      return 0
    fi
  fi
  registrar sistema "Reinicio pendiente" OK "no" "sin reinicio pendiente" \
    "No existe ${FICHERO_REINICIO}."
}

comprobar_ssh() {
  local log=""
  local candidato
  local fallos
  local origenes
  local estado

  if [[ -n "$FICHERO_AUTH" ]]; then
    log=$FICHERO_AUTH
  else
    for candidato in /var/log/auth.log /var/log/secure; do
      if [[ -r "$candidato" ]]; then
        log=$candidato
        break
      fi
    done
  fi

  if [[ -z "$log" || ! -r "$log" ]]; then
    registrar sistema "Accesos SSH fallidos" INFO "no comprobado" "" \
      "No hay log de autenticación legible (/var/log/auth.log o /var/log/secure; puede requerir root o el grupo adm)."
    return 0
  fi

  # Se cuentan las líneas de sshd con «Failed password» o «Invalid user» del
  # log actual (desde su última rotación). grep -c devuelve 1 si no hay
  # coincidencias, pero imprime 0: «|| true» evita que set -e corte.
  fallos=$(grep -cE 'sshd.*(Failed password|Invalid user)' -- "$log" || true)

  # Las tres IP con más fallos. Se usa awk en lugar de «head»: head cierra la
  # tubería antes de tiempo y, con pipefail, la tubería daría error.
  origenes=$(grep -E 'sshd.*(Failed password|Invalid user)' -- "$log" \
              | grep -oE 'from [0-9a-fA-F:.]+' \
              | sort | uniq -c | sort -rn \
              | awk 'NR <= 3 { printf "%s%s (%s)", (NR > 1 ? ", " : ""), $3, $1 }' || true)

  estado=$(evaluar_umbral "$fallos" "$SSH_AVISO" "$SSH_CRITICO")
  registrar sistema "Accesos SSH fallidos" "$estado" "${fallos} en el log actual" \
    "aviso ≥ ${SSH_AVISO} · crítico ≥ ${SSH_CRITICO}" \
    "Fichero: ${log}${origenes:+ · Más intentos desde: ${origenes}}"
}

# ---------------------------------------------------------------------------
# Estado global
# ---------------------------------------------------------------------------
# Prioridad: CRITICAL > WARNING > UNKNOWN > OK. Las comprobaciones INFO no
# cuentan.
declare -A CONTADOR=([OK]=0 [WARNING]=0 [CRITICAL]=0 [UNKNOWN]=0 [INFO]=0)

calcular_estado_global() {
  local estado
  for estado in "${RES_ESTADO[@]}"; do
    CONTADOR[$estado]=$(( CONTADOR[$estado] + 1 ))
  done
  if (( CONTADOR[CRITICAL] > 0 )); then
    ESTADO_GLOBAL=CRITICAL
    CODIGO_SALIDA=2
  elif (( CONTADOR[WARNING] > 0 )); then
    ESTADO_GLOBAL=WARNING
    CODIGO_SALIDA=1
  elif (( CONTADOR[UNKNOWN] > 0 )); then
    ESTADO_GLOBAL=UNKNOWN
    CODIGO_SALIDA=3
  else
    ESTADO_GLOBAL=OK
    CODIGO_SALIDA=0
  fi
}

# Frase de resumen: «1 crítico · 0 avisos · 12 correctos · 3 informativos».
texto_resumen() {
  local texto
  texto="$(plural "${CONTADOR[CRITICAL]}" crítico críticos)"
  texto+=" · $(plural "${CONTADOR[WARNING]}" aviso avisos)"
  texto+=" · $(plural "${CONTADOR[OK]}" correcto correctos)"
  if (( CONTADOR[UNKNOWN] > 0 )); then
    texto+=" · $(plural "${CONTADOR[UNKNOWN]}" desconocido desconocidos)"
  fi
  texto+=" · $(plural "${CONTADOR[INFO]}" informativo informativos)"
  printf '%s' "$texto"
}

# ---------------------------------------------------------------------------
# Salida en terminal
# ---------------------------------------------------------------------------
color_estado() {
  case $1 in
    OK)       printf '%s' "$C_VERDE" ;;
    WARNING)  printf '%s' "$C_AMARILLO" ;;
    CRITICAL) printf '%s' "$C_ROJO" ;;
    UNKNOWN)  printf '%s' "$C_GRIS" ;;
    *)        printf '%s' "$C_AZUL" ;;
  esac
}

mostrar_resumen_terminal() {
  local seccion
  local i
  local etiqueta_estado
  local titulo_mostrado

  printf '\n%sInforme de salud · %s%s\n' "$C_NEGRITA" "$ETIQUETA" "$C_RESET"
  printf '%shost %s · %s · kernel %s · %s núcleos · %s%s\n' "$C_GRIS" "$HOST_NOMBRE" \
    "$SO_NOMBRE" "$KERNEL" "$NUCLEOS" "$FECHA_LEGIBLE" "$C_RESET"

  for seccion in "${SECCIONES[@]}"; do
    titulo_mostrado=0
    for i in "${!RES_NOMBRE[@]}"; do
      if [[ "${RES_SECCION[$i]}" != "$seccion" ]]; then
        continue
      fi
      if (( titulo_mostrado == 0 )); then
        printf '\n%s%s%s\n' "$C_NEGRITA" "${TITULO_SECCION[$seccion]^^}" "$C_RESET"
        titulo_mostrado=1
      fi
      # Se rellena antes de colorear: los códigos de color no ocupan espacio
      # en pantalla pero sí contarían como caracteres.
      etiqueta_estado="[${TEXTO_ESTADO[${RES_ESTADO[$i]}]^^}]"
      printf '  %s%s%s %s %s %s%s%s\n' \
        "$(color_estado "${RES_ESTADO[$i]}")" "$(rellenar "$etiqueta_estado" 13)" "$C_RESET" \
        "$(rellenar "${RES_NOMBRE[$i]}" 26)" \
        "$(rellenar "${RES_VALOR[$i]}" 36)" \
        "$C_GRIS" "${RES_UMBRAL[$i]}" "$C_RESET"
      if (( NIVEL_DETALLE >= 2 )) && [[ -n "${RES_DETALLE[$i]}" ]]; then
        printf '  %s%14s%s%s\n' "$C_GRIS" '' "${RES_DETALLE[$i]}" "$C_RESET"
      fi
    done
  done

  printf '\n%sEstado global: %s%s%s — %s\n' "$C_NEGRITA" \
    "$(color_estado "$ESTADO_GLOBAL")" "$ESTADO_GLOBAL" "$C_RESET" "$(texto_resumen)"
  printf '%sCódigo de salida: %s%s\n\n' "$C_GRIS" "$CODIGO_SALIDA" "$C_RESET"
}

# Una línea al estilo de los plugins de Nagios: «ESTADO - texto | datos».
# Los datos de rendimiento ('etiqueta'=valor%;aviso;crítico;mín;máx) permiten
# a Nagios, Icinga o Zabbix dibujar gráficas.
mostrar_linea_nagios() {
  local i
  local problemas=""
  local rendimiento=""
  local texto

  for i in "${!RES_NOMBRE[@]}"; do
    case ${RES_ESTADO[$i]} in
      WARNING|CRITICAL|UNKNOWN)
        problemas+="${problemas:+; }${RES_NOMBRE[$i]}: ${RES_VALOR[$i]}"
        ;;
      *) ;;   # OK e INFO no se listan
    esac
    if [[ -n "${RES_PORCENTAJE[$i]}" ]]; then
      rendimiento+="${rendimiento:+ }'${RES_NOMBRE[$i]}'=${RES_PORCENTAJE[$i]}%;${RES_AVISO[$i]};${RES_CRITICO[$i]};0;100"
    fi
  done

  if [[ -n "$problemas" ]]; then
    texto=$problemas
  else
    texto="${CONTADOR[OK]} comprobaciones correctas"
  fi
  # «|» separa el texto de los datos de rendimiento: no puede aparecer en el texto.
  printf 'HEALTHCHECK %s - %s | %s\n' "$ESTADO_GLOBAL" "${texto//|//}" "$rendimiento"
}

# ---------------------------------------------------------------------------
# Salida JSON
# ---------------------------------------------------------------------------
# Número JSON o null si está vacío.
json_numero() {
  if [[ -n "$1" ]]; then
    printf '%d' "$1"
  else
    printf 'null'
  fi
}

generar_json() {
  local i
  local separador=""

  printf '{\n'
  printf '  "herramienta": "healthcheck.sh",\n'
  printf '  "version": "%s",\n' "$TOOLKIT_VERSION"
  printf '  "generado": "%s",\n' "$(escapar_json "$FECHA_ISO")"
  printf '  "host": "%s",\n' "$(escapar_json "$HOST_NOMBRE")"
  printf '  "etiqueta": "%s",\n' "$(escapar_json "$ETIQUETA")"
  printf '  "sistema": {\n'
  printf '    "so": "%s",\n' "$(escapar_json "$SO_NOMBRE")"
  printf '    "kernel": "%s",\n' "$(escapar_json "$KERNEL")"
  printf '    "nucleos": %d,\n' "$NUCLEOS"
  printf '    "tiempo_encendido": "%s"\n' "$(escapar_json "${TIEMPO_ENCENDIDO:-}")"
  printf '  },\n'
  printf '  "estado": "%s",\n' "$ESTADO_GLOBAL"
  printf '  "codigo_salida": %d,\n' "$CODIGO_SALIDA"
  printf '  "resumen": {"ok": %d, "warning": %d, "critical": %d, "unknown": %d, "info": %d},\n' \
    "${CONTADOR[OK]}" "${CONTADOR[WARNING]}" "${CONTADOR[CRITICAL]}" "${CONTADOR[UNKNOWN]}" "${CONTADOR[INFO]}"
  printf '  "comprobaciones": [\n'
  for i in "${!RES_NOMBRE[@]}"; do
    printf '%s    {\n' "$separador"
    printf '      "seccion": "%s",\n' "$(escapar_json "${RES_SECCION[$i]}")"
    printf '      "nombre": "%s",\n' "$(escapar_json "${RES_NOMBRE[$i]}")"
    printf '      "estado": "%s",\n' "$(escapar_json "${RES_ESTADO[$i]}")"
    printf '      "valor": "%s",\n' "$(escapar_json "${RES_VALOR[$i]}")"
    printf '      "porcentaje": %s,\n' "$(json_numero "${RES_PORCENTAJE[$i]}")"
    printf '      "umbral_aviso": %s,\n' "$(json_numero "${RES_AVISO[$i]}")"
    printf '      "umbral_critico": %s,\n' "$(json_numero "${RES_CRITICO[$i]}")"
    printf '      "umbral": "%s",\n' "$(escapar_json "${RES_UMBRAL[$i]}")"
    printf '      "detalle": "%s"\n' "$(escapar_json "${RES_DETALLE[$i]}")"
    printf '    }'
    separador=$',\n'
  done
  printf '\n  ]\n}\n'
}

# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
main() {
  local contenido

  buscar_fichero_config "$@"
  if [[ -n "$FICHERO_CONFIG" ]]; then
    cargar_configuracion "$FICHERO_CONFIG"
  fi
  procesar_argumentos "$@"
  validar_ajustes

  recoger_datos_sistema
  comprobar_carga
  comprobar_memoria
  comprobar_discos
  comprobar_servicios
  comprobar_puertos
  comprobar_tiempo_encendido
  comprobar_reinicio_pendiente
  comprobar_ssh
  calcular_estado_global

  # El informe se genera entero en memoria y después se escribe de forma
  # atómica. La asignación va en su propia línea para que, si la generación
  # falla, set -e detenga el script antes de escribir nada.
  if [[ -n "$SALIDA_JSON" ]]; then
    contenido=$(generar_json)
    escribir_atomico "$SALIDA_JSON" "$contenido"
    msg_debug "JSON guardado en ${SALIDA_JSON}"
  fi
  if [[ -n "$SALIDA_HTML" ]]; then
    contenido=$(generar_html)
    escribir_atomico "$SALIDA_HTML" "$contenido"
    msg_debug "HTML guardado en ${SALIDA_HTML}"
  fi

  if (( MODO_NAGIOS == 1 )); then
    mostrar_linea_nagios
  elif (( NIVEL_DETALLE >= 1 )); then
    mostrar_resumen_terminal
  fi

  exit "$CODIGO_SALIDA"
}

main "$@"
