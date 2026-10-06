#!/usr/bin/env bash
#
# escaneo-red.sh — Inventario de una red: qué hosts responden, su nombre
# (DNS inverso) y qué puertos TCP tienen abiertos.
#
# · Barrido con ping de un rango CIDR (máximo /22 = 1024 direcciones) con un
#   número limitado de sondeos en paralelo.
# · Comprobación de puertos TCP con /dev/tcp de bash y «timeout».
# · Si ping no está instalado o no está permitido (falta CAP_NET_RAW, ICMP
#   filtrado...), lo indica y detecta los hosts por TCP: un host está activo
#   si acepta o rechaza activamente una conexión (responde con RST).
#
# Códigos de salida:
#   0 escaneo completado · 1 error · 2 error de uso (rango, puertos...)
#
# Uso responsable: escanea solo redes que administras o con autorización.
#
# Autor: Miguel Ángel Alonso Valhondo — Licencia MIT

set -Eeuo pipefail

DIR_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/comun.sh
source "${DIR_SCRIPT}/../lib/comun.sh"

activar_trampa_errores

readonly PREFIJO_MINIMO=22            # /22 = 1024 direcciones como máximo
readonly MAXIMO_PUERTOS=1024
readonly MAXIMO_PARALELO=256
# Puertos con los que se detectan hosts cuando no se puede usar ping y no se
# ha indicado --puertos.
readonly PUERTOS_DESCUBRIMIENTO=(22 80 443 445 3389)

CIDR=""
TEXTO_PUERTOS=""
PUERTOS=()
PARALELO=32
TIEMPO_ESPERA=1
FORMATO="tabla"
RESOLVER_DNS=1
MOSTRAR_TODOS=0
FORZAR_TCP=0
USAR_PING=1
DIR_TEMPORAL=""

mostrar_ayuda() {
  cat <<'AYUDA'
Uso: escaneo-red.sh [opciones] RED/PREFIJO

Hace inventario de una red IPv4: qué direcciones responden, su nombre por
DNS inverso y, opcionalmente, qué puertos TCP tienen abiertos.

  RED/PREFIJO   rango en notación CIDR, de /22 (1024 direcciones) a /32,
                por ejemplo 192.168.1.0/24 o 10.0.0.0/28

Detección de hosts:
  · con ping (ICMP), si está instalado y permitido;
  · si no, por TCP: un host cuenta como activo si acepta o rechaza la
    conexión en alguno de los puertos (los de --puertos o, si no se
    indican, 22, 80, 443, 445 y 3389). El script avisa cuando pasa a este modo.

Opciones:
  -p, --puertos LISTA   puertos TCP a comprobar, ej. "22,80,443" o "8000-8010"
                        (máximo 1024 puertos)
  -j, --paralelo N      sondeos simultáneos (1-256, por defecto 32)
  -t, --timeout SEG     segundos de espera por sondeo (1-10, por defecto 1)
      --csv             salida en CSV (para hojas de cálculo o scripts)
      --todos           muestra también las direcciones que no responden
      --sin-dns         no resuelve nombres (más rápido)
      --sin-ping        no usa ICMP: detecta los hosts solo por TCP
  -q, --quiet           solo resultados y errores
  -v, --verbose         muestra más detalle
  -h, --help            muestra esta ayuda
      --version         muestra la versión

Códigos de salida:
  0 escaneo completado · 1 error · 2 error de uso

Ejemplos:
  escaneo-red.sh 192.168.1.0/24
  escaneo-red.sh -p 22,80,443 192.168.1.0/24
  escaneo-red.sh --csv -p 22,3389 10.0.0.0/23 > inventario.csv
  escaneo-red.sh --sin-ping -p 8000-8010 127.0.0.1/32

Escanea solo redes que administres o para las que tengas autorización.
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
        printf 'escaneo-red.sh (sysadmin-toolkit) %s\n' "$TOOLKIT_VERSION"
        exit 0
        ;;
      -p|--puertos)  requerir_valor "$1" "${2-}"; TEXTO_PUERTOS=$2; shift ;;
      -j|--paralelo) requerir_valor "$1" "${2-}"; PARALELO=$2; shift ;;
      -t|--timeout)  requerir_valor "$1" "${2-}"; TIEMPO_ESPERA=$2; shift ;;
      --csv)         FORMATO="csv" ;;
      --todos)       MOSTRAR_TODOS=1 ;;
      --sin-dns)     RESOLVER_DNS=0 ;;
      --sin-ping)    FORZAR_TCP=1 ;;
      -q|--quiet)    NIVEL_DETALLE=0 ;;
      -v|--verbose)  NIVEL_DETALLE=2 ;;
      -*) error_uso "Opción desconocida: $1" ;;
      *)
        if [[ -n "$CIDR" ]]; then
          error_uso "Solo se admite un rango (sobra «$1»)."
        fi
        CIDR=$1
        ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------
# Direcciones IP
# ---------------------------------------------------------------------------
# Una IPv4 se maneja como un entero de 32 bits: así calcular la red, la
# difusión y recorrer el rango es simple aritmética.

# 192.168.1.10 -> 3232235786
ip_a_entero() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  printf '%d' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Octeto válido: 0-255 y sin ceros a la izquierda («010» sería octal en bash).
es_octeto() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( $1 <= 255 ))
}

# Valida RED/PREFIJO y calcula PRIMERO y ULTIMO (enteros) del rango de hosts.
analizar_cidr() {
  local texto=$1
  local ip
  local prefijo
  local a b c d
  local direccion
  local mascara
  local red
  local difusion

  if [[ ! "$texto" =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
    error_uso "«${texto}» no es un rango CIDR válido (ejemplo: 192.168.1.0/24)."
  fi
  ip=${BASH_REMATCH[1]}
  prefijo=${BASH_REMATCH[2]}

  IFS=. read -r a b c d <<< "$ip"
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! es_octeto "$a" || ! es_octeto "$b" \
     || ! es_octeto "$c" || ! es_octeto "$d"; then
    error_uso "«${ip}» no es una dirección IPv4 válida."
  fi
  if ! es_entero "$prefijo" || (( prefijo > 32 )); then
    error_uso "Prefijo no válido: /${prefijo}."
  fi
  if (( prefijo < PREFIJO_MINIMO )); then
    error_uso "Rango demasiado grande: /${prefijo} son $(( 1 << (32 - prefijo) )) direcciones; el máximo es /${PREFIJO_MINIMO} (1024)."
  fi

  direccion=$(ip_a_entero "$ip")
  mascara=$(( (0xFFFFFFFF << (32 - prefijo)) & 0xFFFFFFFF ))
  red=$(( direccion & mascara ))
  difusion=$(( red | (~mascara & 0xFFFFFFFF) ))

  if (( red != direccion )); then
    msg_info "${ip} no es la dirección de red; se usa $(entero_a_ip "$red")/${prefijo}."
  fi
  CIDR="$(entero_a_ip "$red")/${prefijo}"

  # En /31 y /32 todas las direcciones son de host (RFC 3021); en el resto
  # se excluyen la dirección de red y la de difusión.
  if (( prefijo >= 31 )); then
    PRIMERO=$red
    ULTIMO=$difusion
  else
    PRIMERO=$(( red + 1 ))
    ULTIMO=$(( difusion - 1 ))
  fi
}

# 3232235786 -> 192.168.1.10
entero_a_ip() {
  local n=$1
  printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# ---------------------------------------------------------------------------
# Puertos
# ---------------------------------------------------------------------------
# "22,80,8000-8010" -> PUERTOS=(22 80 8000 8001 ... 8010)
analizar_puertos() {
  local -a partes
  local parte
  local inicio
  local fin
  local puerto

  if [[ -z "$TEXTO_PUERTOS" ]]; then
    return 0
  fi
  IFS=', ' read -r -a partes <<< "$TEXTO_PUERTOS"
  for parte in "${partes[@]}"; do
    if [[ "$parte" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      inicio=${BASH_REMATCH[1]}
      fin=${BASH_REMATCH[2]}
    elif [[ "$parte" =~ ^[0-9]+$ ]]; then
      inicio=$parte
      fin=$parte
    else
      error_uso "--puertos: «${parte}» no es un puerto ni un rango (ej. 22 o 8000-8010)."
    fi
    if ! es_entero "$inicio" || ! es_entero "$fin" || (( inicio < 1 || fin > 65535 || inicio > fin )); then
      error_uso "--puertos: «${parte}» está fuera de 1-65535 o el rango está al revés."
    fi
    if (( ${#PUERTOS[@]} + fin - inicio + 1 > MAXIMO_PUERTOS )); then
      error_uso "--puertos: como máximo ${MAXIMO_PUERTOS} puertos por escaneo."
    fi
    for (( puerto = inicio; puerto <= fin; puerto++ )); do
      PUERTOS+=("$puerto")
    done
  done
}

validar_ajustes() {
  if [[ -z "$CIDR" ]]; then
    error_uso "Indica el rango a escanear (ejemplo: 192.168.1.0/24)."
  fi
  if ! es_entero "$PARALELO" || (( PARALELO < 1 || PARALELO > MAXIMO_PARALELO )); then
    error_uso "--paralelo debe ser un entero entre 1 y ${MAXIMO_PARALELO}."
  fi
  if ! es_entero "$TIEMPO_ESPERA" || (( TIEMPO_ESPERA < 1 || TIEMPO_ESPERA > 10 )); then
    error_uso "--timeout debe ser un entero entre 1 y 10 (segundos)."
  fi
  analizar_cidr "$CIDR"
  analizar_puertos
  requerir_comandos timeout
}

# ---------------------------------------------------------------------------
# Sondeos
# ---------------------------------------------------------------------------

# Decide si se puede usar ping probando contra 127.0.0.1. Sin permisos para
# ICMP (contenedores sin CAP_NET_RAW, ping_group_range...) ping falla con
# «Operation not permitted»: en ese caso pasamos a detección por TCP.
detectar_ping() {
  local salida
  if (( FORZAR_TCP == 1 )); then
    USAR_PING=0
    msg_info "Detección por TCP (--sin-ping)."
  elif ! command -v ping > /dev/null 2>&1; then
    USAR_PING=0
    msg_aviso "ping no está instalado: los hosts se detectarán por TCP."
  elif ! salida=$(ping -c 1 -W 1 -n 127.0.0.1 2>&1); then
    USAR_PING=0
    msg_aviso "No se puede usar ICMP (${salida%%$'\n'*}): los hosts se detectarán por TCP."
  else
    USAR_PING=1
    msg_debug "ping disponible: detección por ICMP."
  fi

  # Sin ping hacen falta puertos para la detección por TCP.
  if (( USAR_PING == 0 && ${#PUERTOS[@]} == 0 )); then
    PUERTOS=("${PUERTOS_DESCUBRIMIENTO[@]}")
    msg_info "Puertos usados para detectar hosts: ${PUERTOS[*]}"
  fi
}

# Intenta abrir una conexión TCP con /dev/tcp de bash. Escribe:
#   abierto      la conexión se ha establecido
#   rechazado    el host ha respondido con RST: está activo, el puerto cerrado
#   sin_respuesta  tiempo agotado o red inalcanzable (filtrado o apagado)
probar_puerto() {
  local ip=$1
  local puerto=$2
  local salida
  local codigo=0
  # La IP y el puerto se pasan como argumentos ($1 y $2 del bash interno) y
  # no dentro del texto del comando: así nunca se interpretan como código.
  # Por eso las comillas simples son intencionadas.
  # shellcheck disable=SC2016
  salida=$(timeout "$TIEMPO_ESPERA" "$BASH" -c 'exec 3<> "/dev/tcp/$1/$2"' _ "$ip" "$puerto" 2>&1) || codigo=$?
  if (( codigo == 0 )); then
    printf 'abierto'
  elif [[ "$salida" == *"Connection refused"* ]]; then
    printf 'rechazado'
  else
    printf 'sin_respuesta'
  fi
}

# Nombre por DNS inverso (o /etc/hosts) con getent, que respeta nsswitch.conf.
resolver_nombre() {
  local ip=$1
  local salida
  local nombre="-"
  if (( RESOLVER_DNS == 1 )) && salida=$(timeout 2 getent hosts "$ip" 2>/dev/null); then
    read -r _ nombre _ <<< "$salida"
  fi
  # Se limpian caracteres que romperían la salida (separador «|», control).
  nombre=${nombre//[|[:cntrl:]]/}
  printf '%s' "${nombre:--}"
}

# Sondea una dirección y escribe una línea: ip|estado|deteccion|nombre|puertos
sondear_host() {
  local ip=$1
  local activo=0
  local deteccion="-"
  local puerto
  local resultado
  local abiertos=""

  if (( USAR_PING == 1 )); then
    if ping -c 1 -W "$TIEMPO_ESPERA" -n -q "$ip" > /dev/null 2>&1; then
      activo=1
      deteccion="icmp"
    fi
  fi

  # Con ping solo se miran los puertos de los hosts que han respondido; sin
  # ping, los puertos sirven además para saber si el host está activo.
  if (( activo == 1 || USAR_PING == 0 )); then
    for puerto in "${PUERTOS[@]}"; do
      resultado=$(probar_puerto "$ip" "$puerto")
      if [[ "$resultado" == "abierto" ]]; then
        abiertos+="${abiertos:+ }${puerto}"
      fi
      if [[ "$resultado" != "sin_respuesta" && "$activo" == 0 ]]; then
        activo=1
        deteccion="tcp"
      fi
    done
  fi

  if (( activo == 1 )); then
    printf '%s|activo|%s|%s|%s\n' "$ip" "$deteccion" "$(resolver_nombre "$ip")" "${abiertos:--}"
  else
    printf '%s|sin respuesta|-|-|-\n' "$ip"
  fi
}

# Lanza un sondeo por dirección en segundo plano, como máximo PARALELO a la
# vez. Cada sondeo escribe en su propio fichero temporal (nombrado con el
# número de la IP) para no mezclar salidas y poder ordenarlas después.
escanear() {
  local n
  local ip
  local en_marcha=0

  for (( n = PRIMERO; n <= ULTIMO; n++ )); do
    ip=$(entero_a_ip "$n")
    sondear_host "$ip" > "${DIR_TEMPORAL}/$(printf '%010d' "$n")" &
    en_marcha=$(( en_marcha + 1 ))
    if (( en_marcha >= PARALELO )); then
      # wait -n espera a que termine uno cualquiera de los sondeos.
      wait -n || true
      en_marcha=$(( en_marcha - 1 ))
    fi
  done
  wait
}

# ---------------------------------------------------------------------------
# Salida
# ---------------------------------------------------------------------------
mostrar_resultados() {
  local fichero
  local ip
  local estado
  local deteccion
  local nombre
  local puertos

  if [[ "$FORMATO" == "csv" ]]; then
    printf 'ip,estado,deteccion,nombre,puertos_abiertos\n'
  else
    printf '%s%s %s %s %s %s%s\n' "$C_NEGRITA" "$(rellenar "IP" 16)" "$(rellenar "ESTADO" 14)" \
      "$(rellenar "DETECCIÓN" 10)" "$(rellenar "NOMBRE (DNS)" 28)" "PUERTOS ABIERTOS" "$C_RESET"
  fi

  # Los ficheros se llaman con el número de la IP rellenado con ceros, así
  # que el orden del glob es el orden de las direcciones.
  for fichero in "$DIR_TEMPORAL"/*; do
    if [[ ! -s "$fichero" ]]; then
      continue
    fi
    IFS='|' read -r ip estado deteccion nombre puertos < "$fichero"
    if [[ "$estado" != "activo" ]] && (( MOSTRAR_TODOS == 0 )); then
      continue
    fi
    if [[ "$FORMATO" == "csv" ]]; then
      printf '%s,%s,%s,%s,%s\n' "$(escapar_csv "$ip")" "$(escapar_csv "$estado")" \
        "$(escapar_csv "$deteccion")" "$(escapar_csv "$nombre")" "$(escapar_csv "${puertos// /;}")"
    else
      if [[ "$estado" == "activo" ]]; then
        estado="${C_VERDE}$(rellenar "$estado" 14)${C_RESET}"
      else
        estado="${C_GRIS}$(rellenar "$estado" 14)${C_RESET}"
      fi
      printf '%s %s %s %s %s\n' "$(rellenar "$ip" 16)" "$estado" "$(rellenar "$deteccion" 10)" \
        "$(rellenar "$nombre" 28)" "${puertos// /, }"
    fi
  done
}

# Cuenta las direcciones activas a partir de los ficheros de resultados.
contar_activos() {
  local fichero
  local total=0
  local linea
  for fichero in "$DIR_TEMPORAL"/*; do
    if [[ -s "$fichero" ]]; then
      linea=$(< "$fichero")
      if [[ "$linea" == *"|activo|"* ]]; then
        total=$(( total + 1 ))
      fi
    fi
  done
  printf '%d' "$total"
}

limpiar() {
  if [[ -n "$DIR_TEMPORAL" && -d "$DIR_TEMPORAL" ]]; then
    rm -rf -- "$DIR_TEMPORAL"
  fi
}

# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
main() {
  local total
  local activos
  local metodo
  local texto_puertos

  procesar_argumentos "$@"
  validar_ajustes
  detectar_ping

  DIR_TEMPORAL=$(mktemp -d)
  trap limpiar EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  total=$(( ULTIMO - PRIMERO + 1 ))
  if (( USAR_PING == 1 )); then
    metodo="ICMP"
  else
    metodo="TCP"
  fi
  # Los puertos se muestran como se escribieron (un rango «8000-8100» no se
  # despliega en cien números).
  if [[ -n "$TEXTO_PUERTOS" ]]; then
    texto_puertos="${TEXTO_PUERTOS} ($(plural "${#PUERTOS[@]}" puerto puertos))"
  else
    texto_puertos="${PUERTOS[*]:-ninguno}"
  fi
  msg_info "Escaneando ${CIDR}: $(plural "$total" dirección direcciones), detección por ${metodo}, ${PARALELO} sondeos en paralelo, puertos: ${texto_puertos}"

  SECONDS=0
  escanear
  mostrar_resultados

  activos=$(contar_activos)
  msg_ok "Direcciones activas: ${activos} de ${total} en ${CIDR} (detección por ${metodo}, ${SECONDS} s)."
}

main "$@"
