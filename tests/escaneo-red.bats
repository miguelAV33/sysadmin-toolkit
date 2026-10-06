#!/usr/bin/env bats
#
# Pruebas de bin/escaneo-red.sh. Solo se escanea la interfaz de loopback
# (127.0.0.0/8), con un servidor HTTP temporal como puerto abierto.

bats_require_minimum_version 1.5.0

setup_file() {
  load ayudante
  PUERTO_ABIERTO=$(puerto_libre)
  export PUERTO_ABIERTO
  arrancar_servidor "$PUERTO_ABIERTO" "${BATS_FILE_TMPDIR}/servidor.pid"
}

teardown_file() {
  load ayudante
  parar_servidor "${BATS_FILE_TMPDIR}/servidor.pid"
}

setup() {
  load ayudante
  ESC="${BIN}/escaneo-red.sh"
}

# --- Ayuda y argumentos ------------------------------------------------------

@test "escaneo: --help muestra el uso y sale con 0" {
  run "$ESC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: escaneo-red.sh"* ]]
  [[ "$output" == *"/22"* ]]
}

@test "escaneo: sin argumentos -> 2" {
  run "$ESC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Indica el rango"* ]]
}

@test "escaneo: rechaza rangos mayores que /22 -> 2" {
  run "$ESC" 10.0.0.0/21
  [ "$status" -eq 2 ]
  [[ "$output" == *"Rango demasiado grande"* ]]
  run "$ESC" 10.0.0.0/8
  [ "$status" -eq 2 ]
}

@test "escaneo: acepta un /22 (1022 hosts) y respeta el paralelismo" {
  # En loopback todas las direcciones responden: sirve para comprobar que se
  # recorre el rango entero sin perder resultados por el paralelismo.
  run "$ESC" --sin-dns -j 128 127.0.0.0/22
  [ "$status" -eq 0 ]
  [[ "$output" == *"Direcciones activas: 1022 de 1022 en 127.0.0.0/22"* ]]
}

@test "escaneo: rechaza direcciones y prefijos no válidos -> 2" {
  local rango
  for rango in 300.1.1.1/24 10.0.0/24 10.0.0.010/24 10.0.0.0/33 10.0.0.0 abc/24 10.0.0.0/-1; do
    run "$ESC" "$rango"
    [ "$status" -eq 2 ]
  done
}

@test "escaneo: rechaza puertos no válidos -> 2" {
  local puertos
  for puertos in 0 70000 abc 90-80 "22,x"; do
    run "$ESC" -p "$puertos" 127.0.0.1/32
    [ "$status" -eq 2 ]
  done
}

@test "escaneo: rechaza demasiados puertos -> 2" {
  run "$ESC" -p 1-2000 127.0.0.1/32
  [ "$status" -eq 2 ]
  [[ "$output" == *"como máximo 1024"* ]]
}

@test "escaneo: rechaza un paralelismo fuera de rango -> 2" {
  run "$ESC" -j 0 127.0.0.1/32
  [ "$status" -eq 2 ]
  run "$ESC" -j 1000 127.0.0.1/32
  [ "$status" -eq 2 ]
}

# --- Escaneo -----------------------------------------------------------------

@test "escaneo: encuentra el puerto abierto en 127.0.0.1" {
  run "$ESC" -p "22,${PUERTO_ABIERTO}" 127.0.0.1/32
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1"*"activo"*"${PUERTO_ABIERTO}"* ]]
}

@test "escaneo: 127.0.0.0/30 recorre las dos direcciones de host" {
  run --separate-stderr "$ESC" --sin-dns -p "$PUERTO_ABIERTO" 127.0.0.0/30
  [ "$status" -eq 0 ]
  # Cabecera + 127.0.0.1 + 127.0.0.2 (red y difusión no se sondean).
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[1]}" == "127.0.0.1 "*"${PUERTO_ABIERTO}"* ]]
  # El servidor escucha solo en 127.0.0.1: en .2 el puerto está cerrado.
  [[ "${lines[2]}" == "127.0.0.2 "* ]]
  [[ "${lines[2]}" != *"${PUERTO_ABIERTO}"* ]]
}

@test "escaneo: normaliza una IP que no es la de red" {
  run "$ESC" --sin-dns -p "$PUERTO_ABIERTO" 127.0.0.1/30
  [ "$status" -eq 0 ]
  [[ "$output" == *"se usa 127.0.0.0/30"* ]]
}

@test "escaneo: --csv escribe solo CSV en la salida estándar" {
  run --separate-stderr "$ESC" --csv -p "$PUERTO_ABIERTO" 127.0.0.1/32
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ip,estado,deteccion,nombre,puertos_abiertos" ]
  [[ "${lines[1]}" == '"127.0.0.1","activo",'*",\"${PUERTO_ABIERTO}\"" ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "escaneo: --sin-ping detecta el host por TCP" {
  run "$ESC" --sin-ping -p "$PUERTO_ABIERTO" 127.0.0.1/32
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detección por TCP"* ]]
  [[ "$output" == *"127.0.0.1"*"tcp"*"${PUERTO_ABIERTO}"* ]]
}

@test "escaneo: si ping no está permitido lo dice y usa TCP" {
  local falsos
  falsos=$(crear_comando_falso ping 'echo "ping: socket: Operation not permitted" >&2; exit 2')
  PATH="${falsos}:${PATH}" run "$ESC" -p "$PUERTO_ABIERTO" 127.0.0.1/32
  [ "$status" -eq 0 ]
  [[ "$output" == *"No se puede usar ICMP (ping: socket: Operation not permitted)"* ]]
  [[ "$output" == *"127.0.0.1"*"tcp"*"${PUERTO_ABIERTO}"* ]]
}

@test "escaneo: sin ping y sin --puertos usa los puertos de descubrimiento" {
  local falsos
  falsos=$(crear_comando_falso ping 'exit 2')
  PATH="${falsos}:${PATH}" run "$ESC" --sin-dns 127.0.0.1/32
  [ "$status" -eq 0 ]
  [[ "$output" == *"Puertos usados para detectar hosts: 22 80 443 445 3389"* ]]
  # 127.0.0.1 rechaza las conexiones (RST): cuenta como activo.
  [[ "$output" == *"127.0.0.1"*"activo"* ]]
}
