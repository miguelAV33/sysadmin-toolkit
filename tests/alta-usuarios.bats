#!/usr/bin/env bats
#
# Pruebas de bin/alta-usuarios.sh.
#
# Las pruebas normales NUNCA crean usuarios: comprueban el plan (simulación)
# y las validaciones. Las que dan de alta usuarios de verdad solo se ejecutan
# como root y con ALTA_PRUEBAS_REALES=1 (pensadas para un contenedor o una
# máquina virtual desechable); al terminar borran lo que han creado.

bats_require_minimum_version 1.5.0

# Usuarios y grupos de las pruebas reales (nombres que no deberían existir).
readonly USUARIOS_PRUEBA=(zzprueba1 zzprueba2)
readonly GRUPO_PRUEBA=zzgrupoprueba

setup() {
  load ayudante
  ALTA="${BIN}/alta-usuarios.sh"
  CSV="${BATS_TEST_TMPDIR}/usuarios.csv"
}

teardown() {
  # Solo hay algo que limpiar si se han ejecutado las pruebas reales.
  if [[ "${ALTA_PRUEBAS_REALES:-0}" == "1" && $EUID -eq 0 ]]; then
    local usuario
    for usuario in "${USUARIOS_PRUEBA[@]}"; do
      if getent passwd "$usuario" > /dev/null; then
        userdel -r "$usuario" 2> /dev/null || true
      fi
    done
    if getent group "$GRUPO_PRUEBA" > /dev/null; then
      groupdel "$GRUPO_PRUEBA" || true
    fi
  fi
}

escribir_csv() {
  printf '%s\n' "usuario,nombre_completo,grupo,shell" "$@" > "$CSV"
}

requerir_pruebas_reales() {
  if [[ $EUID -ne 0 || "${ALTA_PRUEBAS_REALES:-0}" != "1" ]]; then
    skip "prueba real: requiere root y ALTA_PRUEBAS_REALES=1"
  fi
}

# --- Ayuda y argumentos ------------------------------------------------------

@test "alta: --help muestra el uso y sale con 0" {
  run "$ALTA" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: alta-usuarios.sh"* ]]
  [[ "$output" == *"--aplicar"* ]]
}

@test "alta: sin argumentos -> 2" {
  run "$ALTA"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Indica el fichero CSV"* ]]
}

@test "alta: CSV inexistente -> 2" {
  run "$ALTA" /no/existe.csv
  [ "$status" -eq 2 ]
}

@test "alta: dos ficheros CSV -> 2" {
  escribir_csv
  run "$ALTA" "$CSV" "$CSV"
  [ "$status" -eq 2 ]
}

@test "alta: --longitud fuera de rango -> 2" {
  escribir_csv "zzprueba1,Prueba Uno,${GRUPO_PRUEBA},/bin/bash"
  run "$ALTA" --longitud 6 "$CSV"
  [ "$status" -eq 2 ]
}

# --- Simulación (por defecto) ----------------------------------------------

@test "alta: sin --aplicar muestra el plan y no crea usuarios ni grupos" {
  local antes_passwd antes_group
  antes_passwd=$(sha256sum /etc/passwd)
  antes_group=$(sha256sum /etc/group)
  escribir_csv "zzprueba1,Prueba Uno,${GRUPO_PRUEBA},/bin/bash" \
               "zzprueba2,Prueba Dos,${GRUPO_PRUEBA},/bin/bash"

  run "$ALTA" "$CSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIMULACIÓN"* ]]
  [[ "$output" == *"zzprueba1"*"CREAR"* ]]
  [[ "$output" == *"2 a crear"* ]]
  [[ "$output" == *"1 grupo nuevo (${GRUPO_PRUEBA})"* ]]

  run ! getent passwd zzprueba1
  run ! getent group "$GRUPO_PRUEBA"
  [ "$(sha256sum /etc/passwd)" = "$antes_passwd" ]
  [ "$(sha256sum /etc/group)" = "$antes_group" ]
  # Tampoco se crea el fichero de credenciales.
  [ -z "$(find . -maxdepth 1 -name 'credenciales_*')" ]
}

@test "alta: el CSV de ejemplo del repositorio es válido" {
  run "$ALTA" "${RAIZ}/ejemplos/usuarios.csv"
  [ "$status" -eq 0 ]
}

@test "alta: un usuario que ya existe se omite con un aviso" {
  escribir_csv "root,Administrador,root,/bin/bash"
  run "$ALTA" "$CSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OMITIR: ya existe en el sistema"* ]]
  [[ "$output" == *"1 usuario ya existe y se omitirá"* ]]
}

@test "alta: acepta finales de línea de Windows, BOM y espacios alrededor" {
  printf '\xef\xbb\xbfusuario,nombre_completo,grupo,shell\r\n zzprueba1 , Prueba Uno ,%s, /bin/bash \r\n' \
    "$GRUPO_PRUEBA" > "$CSV"
  run "$ALTA" "$CSV"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zzprueba1"*"Prueba Uno"*"CREAR"* ]]
}

# --- Validación ----------------------------------------------------------------

@test "alta: rechaza nombres de usuario no válidos -> 3" {
  escribir_csv "Pedro.Sanchez,Pedro Sánchez,soporte,/bin/bash" \
               "1abc,Empieza por número,soporte,/bin/bash" \
               "unnombredeusuariomuchomuylargoquesuperalos32,Largo,soporte,/bin/bash"
  run "$ALTA" "$CSV"
  [ "$status" -eq 3 ]
  [[ "$output" == *"3 con errores"* ]]
  [[ "$output" == *"usuario no válido"* ]]
}

@test "alta: rechaza una shell que no está en /etc/shells -> 3" {
  escribir_csv "zzprueba1,Prueba Uno,soporte,/bin/no-existe"
  run "$ALTA" "$CSV"
  [ "$status" -eq 3 ]
  [[ "$output" == *"shell no incluida en /etc/shells"* ]]
}

@test "alta: detecta usuarios repetidos en el CSV -> 3" {
  escribir_csv "zzprueba1,Prueba Uno,soporte,/bin/bash" \
               "zzprueba1,Prueba Repetida,soporte,/bin/bash"
  run "$ALTA" "$CSV"
  [ "$status" -eq 3 ]
  [[ "$output" == *"usuario repetido (ya aparece en la línea 2)"* ]]
}

@test "alta: rechaza filas con un número de campos distinto de 4 -> 3" {
  escribir_csv "zzprueba1,Prueba Uno,soporte" \
               "zzprueba2,Prueba,Dos,soporte,/bin/bash" \
               "zzprueba3,Prueba Tres,soporte,"
  run "$ALTA" "$CSV"
  [ "$status" -eq 3 ]
  [[ "$output" == *"se esperaban 4 campos y hay 3"* ]]
  [[ "$output" == *"se esperaban 4 campos y hay 5"* ]]
  [[ "$output" == *"3 con errores"* ]]
}

@test "alta: rechaza «:» en el nombre y grupos no válidos -> 3" {
  escribir_csv "zzprueba1,Nombre: con dos puntos,soporte,/bin/bash" \
               "zzprueba2,Prueba Dos,Grupo Malo,/bin/bash"
  run "$ALTA" "$CSV"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no puede contener «:»"* ]]
  [[ "$output" == *"grupo no válido"* ]]
}

@test "alta: cabecera incorrecta -> 3" {
  printf 'login,nombre,grupo,shell\nzzprueba1,Prueba,soporte,/bin/bash\n' > "$CSV"
  run "$ALTA" "$CSV"
  [ "$status" -eq 3 ]
  [[ "$output" == *"La primera línea debe ser la cabecera"* ]]
}

# --- Permisos ----------------------------------------------------------------

@test "alta: --aplicar sin ser root -> 4" {
  if [[ $EUID -ne 0 ]]; then
    escribir_csv "zzprueba1,Prueba Uno,soporte,/bin/bash"
    run "$ALTA" --aplicar "$CSV"
  else
    # Como root, lo ejecutamos como «nobody» con setpriv.
    if ! command -v setpriv > /dev/null; then
      skip "falta setpriv"
    fi
    # El directorio temporal de bats solo lo puede leer root: el CSV va a
    # un directorio propio que «nobody» sí puede leer.
    local dir_publico
    dir_publico=$(mktemp -d /tmp/alta-prueba.XXXXXX)
    chmod 755 "$dir_publico"
    printf 'usuario,nombre_completo,grupo,shell\nzzprueba1,Prueba Uno,soporte,/bin/bash\n' > "${dir_publico}/u.csv"
    chmod 644 "${dir_publico}/u.csv"
    run setpriv --reuid=nobody --regid=nogroup --clear-groups "$ALTA" --aplicar "${dir_publico}/u.csv"
    rm -rf -- "$dir_publico"
  fi
  [ "$status" -eq 4 ]
  [[ "$output" == *"hay que ser root"* ]]
}

# --- Alta real (solo en entornos desechables) --------------------------------

@test "alta (real): crea grupo y usuarios, fuerza el cambio de contraseña y guarda credenciales 600" {
  requerir_pruebas_reales
  local credenciales="${BATS_TEST_TMPDIR}/credenciales.csv"
  escribir_csv "zzprueba1,Prueba Uno,${GRUPO_PRUEBA},/bin/bash" \
               "zzprueba2,Prueba Dos,${GRUPO_PRUEBA},/bin/sh"

  run "$ALTA" --aplicar --credenciales "$credenciales" "$CSV"
  [ "$status" -eq 0 ]

  getent group "$GRUPO_PRUEBA"
  run id -gn zzprueba1
  [ "$output" = "$GRUPO_PRUEBA" ]
  [ -d /home/zzprueba1 ]
  [ "$(getent passwd zzprueba2 | cut -d: -f7)" = "/bin/sh" ]
  # chage -d 0: último cambio de contraseña = día 0 -> debe cambiarla al entrar.
  [ "$(getent shadow zzprueba1 | cut -d: -f3)" = "0" ]
  # La contraseña está asignada (no es «!» ni «*»).
  [[ "$(getent shadow zzprueba1 | cut -d: -f2)" == '$'* ]]

  [ "$(stat -c %a "$credenciales")" = "600" ]
  run grep -cE '^zzprueba[12],[A-Za-z0-9]{16}$' "$credenciales"
  [ "$output" = "2" ]
}

@test "alta (real): con errores en el CSV no se crea nada" {
  requerir_pruebas_reales
  escribir_csv "zzprueba1,Prueba Uno,${GRUPO_PRUEBA},/bin/bash" \
               "Mal.Usuario,Prueba Dos,${GRUPO_PRUEBA},/bin/bash"
  run "$ALTA" --aplicar --credenciales "${BATS_TEST_TMPDIR}/c.csv" "$CSV"
  [ "$status" -eq 3 ]
  run ! getent passwd zzprueba1
  run ! getent group "$GRUPO_PRUEBA"
  [ ! -e "${BATS_TEST_TMPDIR}/c.csv" ]
}

@test "alta (real): no sobrescribe un fichero de credenciales existente" {
  requerir_pruebas_reales
  local credenciales="${BATS_TEST_TMPDIR}/credenciales.csv"
  echo "no tocar" > "$credenciales"
  escribir_csv "zzprueba1,Prueba Uno,${GRUPO_PRUEBA},/bin/bash"
  run "$ALTA" --aplicar --credenciales "$credenciales" "$CSV"
  [ "$status" -eq 2 ]
  [ "$(cat "$credenciales")" = "no tocar" ]
  run ! getent passwd zzprueba1
}
