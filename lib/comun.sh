# shellcheck shell=bash
#
# lib/comun.sh — Funciones compartidas por los scripts de sysadmin-toolkit.
#
# Cada script de bin/ carga este fichero con «source». Aquí está todo lo que
# se repite entre scripts:
#   - configuración regional predecible
#   - colores (solo si la salida es una terminal y NO_COLOR no está definida)
#   - mensajes por niveles (silencioso / normal / detallado) y fichero de log
#   - gestión de errores inesperados (trap ERR)
#   - validaciones, formato de números y escapado para JSON, HTML y CSV
#
# Este fichero no se ejecuta solo: no lleva «set -Eeuo pipefail» porque lo
# activa cada script que lo carga.

# Evita cargar la biblioteca dos veces si un script la incluye de nuevo.
if [[ -n "${COMUN_CARGADA:-}" ]]; then
  return 0
fi
readonly COMUN_CARGADA=1

# Versión común de todos los scripts (la muestran con --version).
# shellcheck disable=SC2034  # se usa en los scripts que cargan la biblioteca
readonly TOOLKIT_VERSION="1.0.0"

# Nombre del script que nos ha cargado (para los mensajes y el log).
SCRIPT_NOMBRE="${0##*/}"

# Nivel de detalle de los mensajes: 0 = silencioso, 1 = normal, 2 = detallado.
NIVEL_DETALLE=1

# Si tiene valor, los mensajes se añaden también a este fichero (sin colores).
FICHERO_LOG=""

# Código de salida para errores de uso (opciones incorrectas) y para fallos
# inesperados. Cada script puede cambiarlos: healthcheck.sh usa 3 (UNKNOWN)
# para que un sistema de monitorización no confunda un fallo con un WARNING.
CODIGO_USO=2
CODIGO_ERROR_INESPERADO=1

# ---------------------------------------------------------------------------
# Configuración regional
# ---------------------------------------------------------------------------
# Forzamos una configuración regional conocida:
#   - formato «C»: punto decimal y mensajes de los comandos en inglés, que es
#     lo que analizamos (por ejemplo «Connection refused»);
#   - UTF-8: para que ${#texto} cuente caracteres y no bytes, y las tablas con
#     tildes («García») queden alineadas.
# Se usa una sustitución de proceso en vez de una tubería para no depender de
# pipefail: con «locale -a | grep -q» grep puede cerrar la tubería antes de
# tiempo y la tubería entera daría error aunque haya coincidencia.
if grep -qiE '^c\.utf-?8$' < <(locale -a 2>/dev/null); then
  export LC_ALL=C.UTF-8
else
  export LC_ALL=C
fi

# ---------------------------------------------------------------------------
# Colores
# ---------------------------------------------------------------------------
# Solo usamos colores si la salida estándar es una terminal y el usuario no ha
# definido NO_COLOR (convención https://no-color.org). Así los logs de cron o
# las redirecciones a fichero quedan limpios.
# shellcheck disable=SC2034  # algunos colores solo los usan los scripts
configurar_colores() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_ROJO=$'\e[31m'
    C_VERDE=$'\e[32m'
    C_AMARILLO=$'\e[33m'
    C_AZUL=$'\e[34m'
    C_GRIS=$'\e[90m'
    C_NEGRITA=$'\e[1m'
    C_RESET=$'\e[0m'
  else
    C_ROJO=""
    C_VERDE=""
    C_AMARILLO=""
    C_AZUL=""
    C_GRIS=""
    C_NEGRITA=""
    C_RESET=""
  fi
}
configurar_colores

# ---------------------------------------------------------------------------
# Mensajes
# ---------------------------------------------------------------------------
# Todos los mensajes van a la salida de error (stderr). La salida estándar
# queda reservada para los resultados (tablas, CSV...), de modo que se puede
# redirigir el resultado a un fichero sin mezclarlo con los avisos.

# Añade una línea al fichero de log, si se ha configurado uno.
escribir_log() {
  local nivel=$1
  local texto=$2
  if [[ -n "$FICHERO_LOG" ]]; then
    printf '%s [%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$nivel" \
      "$SCRIPT_NOMBRE" "$texto" >> "$FICHERO_LOG"
  fi
}

msg_info() {
  escribir_log INFO "$*"
  if (( NIVEL_DETALLE >= 1 )); then
    printf '%s[INFO]%s %s\n' "$C_AZUL" "$C_RESET" "$*" >&2
  fi
}

msg_ok() {
  escribir_log OK "$*"
  if (( NIVEL_DETALLE >= 1 )); then
    printf '%s[ OK ]%s %s\n' "$C_VERDE" "$C_RESET" "$*" >&2
  fi
}

msg_aviso() {
  escribir_log AVISO "$*"
  if (( NIVEL_DETALLE >= 1 )); then
    printf '%s[AVISO]%s %s\n' "$C_AMARILLO" "$C_RESET" "$*" >&2
  fi
}

# Los errores se muestran siempre, también en modo silencioso.
msg_error() {
  escribir_log ERROR "$*"
  printf '%s[ERROR]%s %s\n' "$C_ROJO" "$C_RESET" "$*" >&2
}

# Solo con --verbose.
msg_debug() {
  escribir_log DEBUG "$*"
  if (( NIVEL_DETALLE >= 2 )); then
    printf '%s[DEBUG] %s%s\n' "$C_GRIS" "$*" "$C_RESET" >&2
  fi
}

# Muestra un error y termina el script con el código indicado (1 por defecto).
morir() {
  local mensaje=$1
  local codigo=${2:-1}
  msg_error "$mensaje"
  exit "$codigo"
}

# Error de uso: opción desconocida, valor no válido... Recuerda --help.
error_uso() {
  msg_error "$1"
  printf 'Usa «%s --help» para ver las opciones disponibles.\n' "$SCRIPT_NOMBRE" >&2
  exit "$CODIGO_USO"
}

# Comprueba que una opción que necesita valor lo tenga: «--destino» sin nada
# detrás, o seguido de otra opción, es un error de uso.
requerir_valor() {
  local opcion=$1
  local valor=${2-}
  if [[ -z "$valor" || "$valor" == -* ]]; then
    error_uso "La opción ${opcion} necesita un valor."
  fi
}

# ---------------------------------------------------------------------------
# Errores inesperados
# ---------------------------------------------------------------------------
# Con «set -E» la trampa ERR se hereda en funciones y subshells. Si un comando
# falla sin que lo hayamos previsto, se informa de dónde ha sido en vez de
# terminar en silencio.
al_fallar() {
  local codigo=$1
  local fichero=$2
  local linea=$3
  local comando=$4
  msg_error "Fallo inesperado (código ${codigo}) en ${fichero}:${linea}: ${comando}"
  exit "$CODIGO_ERROR_INESPERADO"
}

activar_trampa_errores() {
  trap 'al_fallar "$?" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND"' ERR
}

# ---------------------------------------------------------------------------
# Validaciones
# ---------------------------------------------------------------------------
# Entero sin signo y sin ceros a la izquierda. Rechazamos «08» a propósito:
# en la aritmética de bash un número que empieza por 0 se interpreta en octal.
es_entero() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

es_root() {
  (( EUID == 0 ))
}

# Termina con error de uso si falta algún comando necesario.
requerir_comandos() {
  local comando
  for comando in "$@"; do
    if ! command -v "$comando" > /dev/null 2>&1; then
      morir "Falta el comando «${comando}». Instálalo e inténtalo de nuevo." 1
    fi
  done
}

# Valida un porcentaje (entero de 0 a 100) recibido en una opción.
validar_porcentaje() {
  local opcion=$1
  local valor=$2
  if ! es_entero "$valor" || (( valor > 100 )); then
    error_uso "${opcion}: «${valor}» no es un porcentaje válido (entero de 0 a 100)."
  fi
}

# ---------------------------------------------------------------------------
# Formato
# ---------------------------------------------------------------------------
# Escribe el texto y lo rellena con espacios hasta «ancho» caracteres.
# printf '%-20s' cuenta bytes, no caracteres, y descuadra las palabras con
# tilde; ${#texto} sí cuenta caracteres porque usamos UTF-8.
rellenar() {
  local texto=$1
  local ancho=$2
  local relleno=$(( ancho - ${#texto} ))
  if (( relleno < 0 )); then
    relleno=0
  fi
  printf '%s%*s' "$texto" "$relleno" ''
}

# Convierte bytes a una cantidad legible: 8421236736 -> «7.8 GiB».
# Solo usa aritmética entera de bash; la cifra decimal sale del resto.
formatear_bytes() {
  local entero=$1
  local unidades=(B KiB MiB GiB TiB PiB)
  local indice=0
  local decimal=0
  while (( entero >= 1024 && indice < 5 )); do
    decimal=$(( (entero % 1024) * 10 / 1024 ))
    entero=$(( entero / 1024 ))
    indice=$(( indice + 1 ))
  done
  if (( indice == 0 )); then
    printf '%d B' "$entero"
  else
    printf '%d.%d %s' "$entero" "$decimal" "${unidades[$indice]}"
  fi
}

# Agrupa las cifras de tres en tres: 16777216 -> «16 777 216». El separador
# es un espacio duro (U+00A0, bytes C2 A0) para que el número no se parta en
# dos líneas en el informe HTML.
separar_miles() {
  local numero=$1
  local resultado=""
  local espacio=$'\xc2\xa0'
  while (( ${#numero} > 3 )); do
    resultado="${espacio}${numero: -3}${resultado}"
    numero=${numero:0:${#numero}-3}
  done
  printf '%s%s' "$numero" "$resultado"
}

# Número con su palabra en singular o plural: «1 proceso», «6 procesos».
# Uso: plural 6 proceso procesos
plural() {
  local cantidad=$1
  local singular=$2
  local plural=$3
  if (( cantidad == 1 )); then
    printf '%d %s' "$cantidad" "$singular"
  else
    printf '%d %s' "$cantidad" "$plural"
  fi
}

# Convierte segundos a «3 d 4 h 12 min».
formatear_duracion() {
  local segundos=$1
  local dias=$(( segundos / 86400 ))
  local horas=$(( (segundos % 86400) / 3600 ))
  local minutos=$(( (segundos % 3600) / 60 ))
  if (( dias > 0 )); then
    printf '%d d %d h %d min' "$dias" "$horas" "$minutos"
  elif (( horas > 0 )); then
    printf '%d h %d min' "$horas" "$minutos"
  else
    printf '%d min' "$minutos"
  fi
}

# ---------------------------------------------------------------------------
# Escapado de valores
# ---------------------------------------------------------------------------
# Cualquier dato que venga del sistema (nombres de montaje, servicios, la
# etiqueta que escribe el usuario...) se escapa antes de meterlo en un JSON,
# un HTML o un CSV. Así un nombre raro no rompe el fichero ni inyecta código.

# Cadena JSON (sin las comillas exteriores).
escapar_json() {
  local texto=$1
  texto=${texto//\\/\\\\}          # \  ->  \\   (siempre lo primero)
  texto=${texto//\"/\\\"}          # "  ->  \"
  texto=${texto//$'\n'/\\n}        # salto de línea
  texto=${texto//$'\r'/\\r}        # retorno de carro
  texto=${texto//$'\t'/\\t}        # tabulador
  texto=${texto//[[:cntrl:]]/}     # el resto de caracteres de control se eliminan
  printf '%s' "$texto"
}

# Texto para insertar en HTML (contenido o atributos entre comillas).
# Las sustituciones van entre comillas a propósito: desde bash 5.2
# (patsub_replacement) un «&» sin comillas en la sustitución equivale al
# texto encontrado, y «${t//</&lt;}» daría «<lt;» en vez de «&lt;».
escapar_html() {
  local texto=$1
  texto=${texto//'&'/'&amp;'}      # & siempre lo primero
  texto=${texto//'<'/'&lt;'}
  texto=${texto//'>'/'&gt;'}
  texto=${texto//'"'/'&quot;'}
  texto=${texto//"'"/'&#39;'}
  printf '%s' "$texto"
}

# Campo CSV: siempre entre comillas dobles, duplicando las comillas internas
# (RFC 4180). Así una coma dentro del valor no desplaza las columnas.
escapar_csv() {
  local texto=$1
  printf '"%s"' "${texto//\"/\"\"}"
}

# ---------------------------------------------------------------------------
# Ficheros
# ---------------------------------------------------------------------------
# Escribe un texto en «destino» de forma atómica: primero en un temporal del
# mismo directorio y después «mv» (que dentro de un mismo sistema de ficheros
# es atómico). Quien lea el fichero (un servidor web, otro script) nunca verá
# un informe a medio escribir.
# Uso: escribir_atomico /ruta/informe.json "$contenido"
escribir_atomico() {
  local destino=$1
  local contenido=$2
  local temporal
  local permisos
  temporal=$(mktemp "${destino}.tmp.XXXXXX")
  if ! printf '%s\n' "$contenido" > "$temporal"; then
    rm -f -- "$temporal"
    return 1
  fi
  # mktemp crea el fichero con permisos 600; aplicamos los que daría una
  # redirección normal según la umask (por ejemplo 644 con umask 022).
  permisos=$(( 8#666 & ~8#$(umask) ))
  chmod "$(printf '%o' "$permisos")" "$temporal"
  mv -f -- "$temporal" "$destino"
}
