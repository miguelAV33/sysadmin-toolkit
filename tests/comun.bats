#!/usr/bin/env bats
#
# Pruebas de las funciones de lib/comun.sh.

bats_require_minimum_version 1.5.0

setup() {
  load ayudante
  # shellcheck source=../lib/comun.sh
  source "${RAIZ}/lib/comun.sh"
}

@test "escapar_html convierte los cinco caracteres especiales" {
  run escapar_html "<a href=\"x\">Tom & Jerry's</a>"
  [ "$status" -eq 0 ]
  [ "$output" = "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;" ]
}

@test "escapar_html no se ve afectado por patsub_replacement de bash 5.2" {
  run escapar_html "<"
  [ "$output" = "&lt;" ]
}

@test "escapar_json escapa comillas, barras y caracteres de control" {
  run escapar_json "$(printf 'a"b\\c\nd\te\001f')"
  [ "$output" = 'a\"b\\c\nd\tef' ]
  printf '"%s"' "$output" | python3 -m json.tool > /dev/null
}

@test "escapar_csv entrecomilla y duplica las comillas internas" {
  run escapar_csv 'dice "hola", adiós'
  [ "$output" = '"dice ""hola"", adiós"' ]
}

@test "es_entero acepta enteros y rechaza ceros a la izquierda y texto" {
  es_entero 0
  es_entero 42
  # «run !» exige que el comando falle (un «!» suelto no haría fallar la prueba).
  run ! es_entero 08
  run ! es_entero -1
  run ! es_entero 1.5
  run ! es_entero ""
}

@test "rellenar cuenta caracteres, no bytes (tildes alineadas)" {
  run rellenar "García" 8
  [ "$output" = "García  " ]
  run rellenar "Garcia" 8
  [ "$output" = "Garcia  " ]
}

@test "formatear_bytes usa unidades binarias con un decimal" {
  run formatear_bytes 512
  [ "$output" = "512 B" ]
  run formatear_bytes 1536
  [ "$output" = "1.5 KiB" ]
  run formatear_bytes 8421236736
  [ "$output" = "7.8 GiB" ]
}

@test "formatear_duracion muestra días, horas y minutos" {
  run formatear_duracion 273720
  [ "$output" = "3 d 4 h 2 min" ]
  run formatear_duracion 59
  [ "$output" = "0 min" ]
}

@test "plural elige singular o plural según la cantidad" {
  run plural 1 proceso procesos
  [ "$output" = "1 proceso" ]
  run plural 0 proceso procesos
  [ "$output" = "0 procesos" ]
  run plural 6 "grupo nuevo" "grupos nuevos"
  [ "$output" = "6 grupos nuevos" ]
}

@test "sin terminal no se usan colores" {
  configurar_colores
  [ -z "$C_ROJO" ]
  [ -z "$C_RESET" ]
}
