#!/usr/bin/env bash
#
# alta-usuarios.sh — Alta masiva de usuarios Linux a partir de un CSV.
#
# Formato del CSV (con cabecera):
#   usuario,nombre_completo,grupo,shell
#   lgarcia,Lucía García,desarrollo,/bin/bash
#
# SEGURO POR DEFECTO: sin --aplicar solo muestra el plan (qué usuarios y
# grupos se crearían) y no modifica nada. Con --aplicar, y solo si TODAS las
# filas son válidas, crea los grupos que falten y los usuarios con su
# directorio personal, les asigna una contraseña temporal aleatoria, les
# obliga a cambiarla en el primer inicio de sesión y guarda las credenciales
# en un fichero con permisos 600.
#
# Códigos de salida:
#   0 correcto · 1 fallo al aplicar · 2 error de uso · 3 CSV con errores
#   4 se necesita ser root para --aplicar
#
# Autor: Miguel Ángel Alonso Valhondo — Licencia MIT

set -Eeuo pipefail

DIR_SCRIPT="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib/comun.sh
source "${DIR_SCRIPT}/../lib/comun.sh"

readonly CODIGO_DATOS=3
readonly CODIGO_PERMISOS=4
activar_trampa_errores

readonly CABECERA_ESPERADA="usuario,nombre_completo,grupo,shell"
# Nombres de usuario y grupo según la convención de useradd/POSIX: empieza
# por minúscula o «_», después minúsculas, números, «_» o «-», máximo 32.
readonly REGEX_NOMBRE='^[a-z_][a-z0-9_-]{0,31}$'

APLICAR=0
FICHERO_CSV=""
FICHERO_CREDENCIALES=""
LONGITUD_CONTRASENA=16

# Filas del CSV ya analizadas (arrays paralelos: el índice i es la misma fila).
FILA_LINEA=()
FILA_USUARIO=()
FILA_NOMBRE=()
FILA_GRUPO=()
FILA_SHELL=()
FILA_ACCION=()    # CREAR, OMITIR o ERROR
FILA_MOTIVO=()

declare -A GRUPOS_NUEVOS=()      # grupos que no existen y hay que crear
declare -A USUARIO_EN_LINEA=()   # para detectar usuarios repetidos en el CSV

mostrar_ayuda() {
  cat <<'AYUDA'
Uso: alta-usuarios.sh [opciones] FICHERO.csv

Da de alta usuarios Linux a partir de un CSV con cabecera:
  usuario,nombre_completo,grupo,shell

Sin --aplicar solo muestra el plan: NO crea nada y no necesita ser root.

Validaciones de cada fila (si alguna falla, no se aplica nada):
  · 4 campos separados por comas (el nombre completo no puede llevar comas)
  · usuario y grupo: ^[a-z_][a-z0-9_-]{0,31}$ (convención de useradd)
  · nombre completo no vacío y sin «:»
  · shell incluida en /etc/shells y ejecutable
  · usuarios repetidos dentro del CSV
Los usuarios que ya existen en el sistema se omiten con un aviso.

Al aplicar (--aplicar, como root):
  · crea los grupos que falten (groupadd)
  · crea cada usuario con su directorio personal y el grupo indicado como
    grupo principal (useradd -m -g)
  · asigna una contraseña temporal aleatoria (/dev/urandom) con chpasswd
  · obliga a cambiarla en el primer inicio de sesión (chage -d 0)
  · guarda «usuario,contraseña» en el fichero de credenciales (permisos 600)

Opciones:
      --aplicar              crea realmente los grupos y usuarios (requiere root)
      --credenciales FICHERO dónde guardar las contraseñas temporales (por
                             defecto ./credenciales_AAAAMMDD_HHMMSS.csv; no
                             se sobrescribe un fichero existente)
      --longitud N           longitud de las contraseñas (12-64, por defecto 16)
  -q, --quiet                solo muestra errores (y el plan)
  -v, --verbose              muestra más detalle
  -h, --help                 muestra esta ayuda
      --version              muestra la versión

Códigos de salida:
  0 correcto · 1 fallo al aplicar algún cambio · 2 error de uso
  3 el CSV tiene filas no válidas · 4 --aplicar sin ser root

Ejemplos:
  alta-usuarios.sh ejemplos/usuarios.csv                 # solo muestra el plan
  sudo alta-usuarios.sh --aplicar ejemplos/usuarios.csv
  sudo alta-usuarios.sh --aplicar --credenciales /root/altas-octubre.csv nuevos.csv
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
        printf 'alta-usuarios.sh (sysadmin-toolkit) %s\n' "$TOOLKIT_VERSION"
        exit 0
        ;;
      --aplicar)      APLICAR=1 ;;
      --credenciales) requerir_valor "$1" "${2-}"; FICHERO_CREDENCIALES=$2; shift ;;
      --longitud)     requerir_valor "$1" "${2-}"; LONGITUD_CONTRASENA=$2; shift ;;
      -q|--quiet)     NIVEL_DETALLE=0 ;;
      -v|--verbose)   NIVEL_DETALLE=2 ;;
      -*) error_uso "Opción desconocida: $1" ;;
      *)
        if [[ -n "$FICHERO_CSV" ]]; then
          error_uso "Solo se admite un fichero CSV (sobra «$1»)."
        fi
        FICHERO_CSV=$1
        ;;
    esac
    shift
  done
}

validar_ajustes() {
  if [[ -z "$FICHERO_CSV" ]]; then
    error_uso "Indica el fichero CSV."
  fi
  if [[ ! -f "$FICHERO_CSV" || ! -r "$FICHERO_CSV" ]]; then
    error_uso "No se puede leer el fichero: ${FICHERO_CSV}"
  fi
  if ! es_entero "$LONGITUD_CONTRASENA" || (( LONGITUD_CONTRASENA < 12 || LONGITUD_CONTRASENA > 64 )); then
    error_uso "--longitud debe ser un entero entre 12 y 64."
  fi
  if [[ -z "$FICHERO_CREDENCIALES" ]]; then
    FICHERO_CREDENCIALES="./credenciales_$(date '+%Y%m%d_%H%M%S').csv"
  fi

  # Root solo hace falta para aplicar; se comprueba antes de hacer nada.
  if (( APLICAR == 1 )) && ! es_root; then
    morir "Para aplicar los cambios hay que ser root (prueba con sudo). Sin --aplicar se muestra el plan sin necesidad de root." "$CODIGO_PERMISOS"
  fi
  if (( APLICAR == 1 )); then
    requerir_comandos useradd groupadd chpasswd chage getent
    if [[ -e "$FICHERO_CREDENCIALES" ]]; then
      error_uso "El fichero de credenciales ya existe y no se sobrescribe: ${FICHERO_CREDENCIALES}"
    fi
    if [[ ! -d "$(dirname -- "$FICHERO_CREDENCIALES")" ]]; then
      error_uso "No existe el directorio de ${FICHERO_CREDENCIALES}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Lectura y validación del CSV
# ---------------------------------------------------------------------------

# Quita espacios al principio y al final: «  Lucía García » -> «Lucía García».
recortar() {
  local texto=$1
  if [[ "$texto" =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# ¿Está la shell en /etc/shells (sin contar comentarios)?
shell_permitida() {
  local shell=$1
  local linea
  while IFS= read -r linea; do
    if [[ "$linea" == "$shell" ]]; then
      return 0
    fi
  done < /etc/shells
  return 1
}

# Valida una fila y la añade a los arrays FILA_*.
analizar_fila() {
  local numero=$1
  local linea=$2
  local comas
  local usuario=""
  local nombre=""
  local grupo=""
  local shell=""
  local errores=""
  local accion
  local motivo

  IFS=',' read -r usuario nombre grupo shell <<< "$linea"
  usuario=$(recortar "$usuario")
  nombre=$(recortar "$nombre")
  grupo=$(recortar "$grupo")
  shell=$(recortar "$shell")

  # Contamos las comas en vez de fiarnos de «read»: read descarta un último
  # campo vacío («a,b,c,») y no detectaríamos la fila incompleta.
  comas=${linea//[^,]/}
  if (( ${#comas} != 3 )); then
    errores="se esperaban 4 campos y hay $(( ${#comas} + 1 ))"
  else
    if [[ ! "$usuario" =~ $REGEX_NOMBRE ]]; then
      errores+="${errores:+; }usuario no válido"
    fi
    if [[ -z "$nombre" ]]; then
      errores+="${errores:+; }falta el nombre completo"
    elif [[ "$nombre" == *:* ]]; then
      # El campo GECOS de /etc/passwd no puede contener «:» (es el separador).
      errores+="${errores:+; }el nombre no puede contener «:»"
    fi
    if [[ ! "$grupo" =~ $REGEX_NOMBRE ]]; then
      errores+="${errores:+; }grupo no válido"
    fi
    if ! shell_permitida "$shell"; then
      errores+="${errores:+; }shell no incluida en /etc/shells"
    elif [[ ! -x "$shell" ]]; then
      errores+="${errores:+; }la shell no existe o no es ejecutable"
    fi
    if [[ -n "$usuario" && -n "${USUARIO_EN_LINEA[$usuario]:-}" ]]; then
      errores+="${errores:+; }usuario repetido (ya aparece en la línea ${USUARIO_EN_LINEA[$usuario]})"
    elif [[ -n "$usuario" ]]; then
      USUARIO_EN_LINEA[$usuario]=$numero
    fi
  fi

  if [[ -n "$errores" ]]; then
    accion=ERROR
    motivo=$errores
  elif getent passwd "$usuario" > /dev/null 2>&1; then
    accion=OMITIR
    motivo="ya existe en el sistema"
  else
    accion=CREAR
    motivo=""
    if ! getent group "$grupo" > /dev/null 2>&1; then
      GRUPOS_NUEVOS[$grupo]=1
      motivo="grupo nuevo"
    fi
  fi

  FILA_LINEA+=("$numero")
  FILA_USUARIO+=("$usuario")
  FILA_NOMBRE+=("$nombre")
  FILA_GRUPO+=("$grupo")
  FILA_SHELL+=("$shell")
  FILA_ACCION+=("$accion")
  FILA_MOTIVO+=("$motivo")
}

leer_csv() {
  local linea
  local numero=0
  local cabecera

  while IFS= read -r linea || [[ -n "$linea" ]]; do
    numero=$(( numero + 1 ))
    linea=${linea%$'\r'}                  # CSV exportado desde Windows (CRLF)

    if (( numero == 1 )); then
      linea=${linea#$'\xef\xbb\xbf'}      # BOM que añaden algunos programas (Excel)
      cabecera=${linea// /}
      if [[ "${cabecera,,}" != "$CABECERA_ESPERADA" ]]; then
        morir "La primera línea debe ser la cabecera «${CABECERA_ESPERADA}» y es «${linea}»." "$CODIGO_DATOS"
      fi
      continue
    fi
    # Líneas vacías y comentarios.
    if [[ "$linea" =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    analizar_fila "$numero" "$linea"
  done < "$FICHERO_CSV"

  if (( numero == 0 )); then
    morir "El fichero CSV está vacío: ${FICHERO_CSV}" "$CODIGO_DATOS"
  fi
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------
contar_acciones() {
  local accion=$1
  local total=0
  local valor
  for valor in "${FILA_ACCION[@]}"; do
    if [[ "$valor" == "$accion" ]]; then
      total=$(( total + 1 ))
    fi
  done
  printf '%d' "$total"
}

# Texto seguro para la terminal: sin caracteres de control (un CSV podría
# traer secuencias de escape que alteren la pantalla).
para_pantalla() {
  printf '%s' "${1//[[:cntrl:]]/?}"
}

mostrar_plan() {
  local i
  local color
  local texto_accion

  if (( APLICAR == 1 )); then
    printf '\n%sPlan de alta%s (%s)\n\n' "$C_NEGRITA" "$C_RESET" "$FICHERO_CSV"
  else
    printf '\n%sPlan de alta%s (%s) · %sSIMULACIÓN: no se modifica nada%s\n\n' \
      "$C_NEGRITA" "$C_RESET" "$FICHERO_CSV" "$C_AMARILLO" "$C_RESET"
  fi
  printf '%s%s %s %s %s %s %s%s\n' "$C_GRIS" "$(rellenar "LÍNEA" 6)" "$(rellenar "USUARIO" 14)" \
    "$(rellenar "NOMBRE" 26)" "$(rellenar "GRUPO" 14)" "$(rellenar "SHELL" 14)" "ACCIÓN" "$C_RESET"

  for i in "${!FILA_LINEA[@]}"; do
    case ${FILA_ACCION[$i]} in
      CREAR)  color=$C_VERDE ;;
      OMITIR) color=$C_AMARILLO ;;
      *)      color=$C_ROJO ;;
    esac
    texto_accion=${FILA_ACCION[$i]}${FILA_MOTIVO[$i]:+: ${FILA_MOTIVO[$i]}}
    printf '%s %s %s %s %s %s%s%s\n' \
      "$(rellenar "${FILA_LINEA[$i]}" 6)" \
      "$(rellenar "$(para_pantalla "${FILA_USUARIO[$i]}")" 14)" \
      "$(rellenar "$(para_pantalla "${FILA_NOMBRE[$i]}")" 26)" \
      "$(rellenar "$(para_pantalla "${FILA_GRUPO[$i]}")" 14)" \
      "$(rellenar "$(para_pantalla "${FILA_SHELL[$i]}")" 14)" \
      "$color" "$(para_pantalla "$texto_accion")" "$C_RESET"
  done

  printf '\nResumen: %s a crear · %s · %s con errores · %s' \
    "$(contar_acciones CREAR)" "$(plural "$(contar_acciones OMITIR)" omitido omitidos)" \
    "$(contar_acciones ERROR)" "$(plural "${#GRUPOS_NUEVOS[@]}" "grupo nuevo" "grupos nuevos")"
  if (( ${#GRUPOS_NUEVOS[@]} > 0 )); then
    printf ' (%s)' "$(printf '%s\n' "${!GRUPOS_NUEVOS[@]}" | sort | paste -sd ' ')"
  fi
  printf '\n\n'
}

# ---------------------------------------------------------------------------
# Aplicación
# ---------------------------------------------------------------------------

# Contraseña aleatoria a partir de /dev/urandom. Se omiten caracteres que se
# confunden al leerlos (0/O, 1/l/I). «head -c 256» lee un bloque fijo y
# termina; tr filtra los caracteres válidos. No se usa «tr < /dev/urandom |
# head», porque con pipefail tr acabaría con error al cerrarse la tubería.
generar_contrasena() {
  local longitud=$1
  local contrasena=""
  while (( ${#contrasena} < longitud )); do
    contrasena+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')
  done
  printf '%s' "${contrasena:0:longitud}"
}

# Crea el fichero de credenciales vacío con permisos 600 ANTES de tocar el
# sistema: si no se puede crear, no se da de alta a nadie.
crear_fichero_credenciales() {
  # noclobber hace que «>» falle si el fichero ya existe (por si aparece
  # entre la validación y este momento). umask 077 -> permisos 600.
  ( umask 077 && set -o noclobber && : > "$FICHERO_CREDENCIALES" ) \
    || morir "No se puede crear el fichero de credenciales ${FICHERO_CREDENCIALES}" 1
  chmod 600 -- "$FICHERO_CREDENCIALES"
  {
    printf '# Credenciales temporales generadas por alta-usuarios.sh el %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# Cada usuario debe cambiar la contraseña en su primer inicio de sesión.\n'
    printf '# Entrega cada contraseña por un canal seguro y después borra este fichero (shred -u).\n'
    printf 'usuario,contrasena_temporal\n'
  } >> "$FICHERO_CREDENCIALES"
}

aplicar_cambios() {
  local grupo
  local -a grupos_ordenados=()
  local i
  local usuario
  local contrasena
  local creados=0
  local fallos=0

  crear_fichero_credenciales

  # Las claves de un array asociativo no tienen orden: se ordenan para que
  # la salida sea siempre la misma.
  if (( ${#GRUPOS_NUEVOS[@]} > 0 )); then
    mapfile -t grupos_ordenados < <(printf '%s\n' "${!GRUPOS_NUEVOS[@]}" | sort)
  fi
  for grupo in "${grupos_ordenados[@]}"; do
    if groupadd "$grupo"; then
      msg_ok "Grupo creado: ${grupo}"
    else
      msg_error "No se ha podido crear el grupo ${grupo}"
      fallos=$(( fallos + 1 ))
    fi
  done

  for i in "${!FILA_LINEA[@]}"; do
    if [[ "${FILA_ACCION[$i]}" != "CREAR" ]]; then
      continue
    fi
    usuario=${FILA_USUARIO[$i]}

    if ! useradd --create-home --comment "${FILA_NOMBRE[$i]}" --gid "${FILA_GRUPO[$i]}" \
         --shell "${FILA_SHELL[$i]}" "$usuario"; then
      msg_error "useradd ha fallado para ${usuario} (línea ${FILA_LINEA[$i]})"
      fallos=$(( fallos + 1 ))
      continue
    fi

    # La contraseña se pasa a chpasswd por la entrada estándar, nunca como
    # argumento: los argumentos de un proceso son visibles con «ps».
    contrasena=$(generar_contrasena "$LONGITUD_CONTRASENA")
    if ! printf '%s:%s\n' "$usuario" "$contrasena" | chpasswd; then
      # useradd deja la cuenta bloqueada hasta que tenga contraseña: estado seguro.
      msg_error "No se ha podido asignar la contraseña a ${usuario}; la cuenta queda bloqueada."
      fallos=$(( fallos + 1 ))
      continue
    fi

    # Caducidad en el día 0: obliga a cambiar la contraseña al entrar.
    if ! chage --lastday 0 "$usuario"; then
      msg_error "No se ha podido forzar el cambio de contraseña de ${usuario}"
      fallos=$(( fallos + 1 ))
    fi

    printf '%s,%s\n' "$usuario" "$contrasena" >> "$FICHERO_CREDENCIALES"
    msg_ok "Usuario creado: ${usuario} (${FILA_NOMBRE[$i]}, grupo ${FILA_GRUPO[$i]})"
    creados=$(( creados + 1 ))
  done

  msg_info "Usuarios creados: ${creados}. Credenciales en ${FICHERO_CREDENCIALES} (permisos 600)."
  if (( fallos > 0 )); then
    morir "Ha habido $(plural "$fallos" fallo fallos) al aplicar los cambios; revisa los mensajes anteriores." 1
  fi
}

# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------
main() {
  local errores
  local omitidos
  local a_crear

  procesar_argumentos "$@"
  validar_ajustes
  leer_csv
  mostrar_plan

  errores=$(contar_acciones ERROR)
  omitidos=$(contar_acciones OMITIR)
  a_crear=$(contar_acciones CREAR)

  if (( omitidos > 0 )); then
    msg_aviso "$(plural "$omitidos" "usuario ya existe y se omitirá" "usuarios ya existen y se omitirán")."
  fi
  if (( errores > 0 )); then
    morir "El CSV tiene $(plural "$errores" fila filas) con errores. Corrígelas: no se aplica nada mientras haya errores." "$CODIGO_DATOS"
  fi
  if (( a_crear == 0 )); then
    msg_info "No hay usuarios nuevos que crear."
    exit 0
  fi

  if (( APLICAR == 0 )); then
    msg_info "Simulación terminada. Para crear los usuarios: sudo ${SCRIPT_NOMBRE} --aplicar ${FICHERO_CSV}"
    exit 0
  fi

  aplicar_cambios
  msg_ok "Alta terminada."
}

main "$@"
