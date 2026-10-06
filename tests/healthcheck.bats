#!/usr/bin/env bats
#
# Pruebas de bin/healthcheck.sh.
#
# Para que el resultado no dependa de la máquina donde se ejecutan, casi
# todas las pruebas parten de umbrales «laxos» (nada salta) y fuerzan solo
# la comprobación que quieren probar.

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
  HC="${BIN}/healthcheck.sh"
  # Umbrales que no saltan nunca (salvo un disco lleno al 100 %), sin marca
  # de reinicio y con un log de autenticación vacío.
  LAXOS=(
    --disk-warn 100 --disk-crit 100 --inode-warn 100 --inode-crit 100
    --mem-warn 100 --mem-crit 100 --swap-warn 100 --swap-crit 100
    --load-warn 10000 --load-crit 10000
    --fichero-reinicio "${BATS_TEST_TMPDIR}/no-existe"
    --auth-log /dev/null
  )
}

# --- Ayuda y argumentos ------------------------------------------------------

@test "healthcheck: --help muestra el uso y sale con 0" {
  run "$HC" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: healthcheck.sh"* ]]
  [[ "$output" == *"--disk-warn"* ]]
}

@test "healthcheck: --version muestra la versión" {
  run "$HC" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "healthcheck.sh (sysadmin-toolkit) "* ]]
}

@test "healthcheck: opción desconocida -> 3 (UNKNOWN)" {
  run "$HC" --no-existe
  [ "$status" -eq 3 ]
  [[ "$output" == *"Opción desconocida"* ]]
}

@test "healthcheck: umbral no numérico -> 3" {
  run "$HC" --disk-warn abc
  [ "$status" -eq 3 ]
  [[ "$output" == *"enteros"* ]]
}

@test "healthcheck: aviso mayor que crítico -> 3" {
  run "$HC" --disk-warn 95 --disk-crit 90
  [ "$status" -eq 3 ]
  [[ "$output" == *"no puede ser mayor"* ]]
}

@test "healthcheck: opción sin valor -> 3" {
  run "$HC" --json
  [ "$status" -eq 3 ]
  [[ "$output" == *"necesita un valor"* ]]
}

@test "healthcheck: porcentaje mayor que 100 -> 3" {
  run "$HC" --mem-warn 90 --mem-crit 150
  [ "$status" -eq 3 ]
}

# --- Códigos de salida ------------------------------------------------------

@test "healthcheck: con umbrales laxos todo está OK -> 0" {
  run "$HC" "${LAXOS[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Estado global: OK"* ]]
}

@test "healthcheck: --mem-warn 0 fuerza WARNING -> 1" {
  run "$HC" "${LAXOS[@]}" --mem-warn 0 --mem-crit 100
  [ "$status" -eq 1 ]
  [[ "$output" == *"[AVISO]"*"Memoria"* ]]
  [[ "$output" == *"Estado global: WARNING"* ]]
}

@test "healthcheck: --disk-warn 0 --disk-crit 0 fuerza CRITICAL -> 2" {
  run "$HC" "${LAXOS[@]}" --disk-warn 0 --disk-crit 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"[CRÍTICO]"*"Disco /"* ]]
  [[ "$output" == *"Estado global: CRITICAL"* ]]
}

@test "healthcheck: la raíz / se revisa siempre" {
  run "$HC" "${LAXOS[@]}"
  [[ "$output" == *"Disco /  "* ]]
}

@test "healthcheck: --excluir-montaje ignora los montajes que encajan" {
  run "$HC" "${LAXOS[@]}" --disk-warn 0 --disk-crit 0 --inode-warn 0 --inode-crit 0 --excluir-montaje '*'
  # Sin discos que revisar el resultado es UNKNOWN (3), no CRITICAL.
  [ "$status" -eq 3 ]
  [[ "$output" == *"sin datos"* ]]
}

@test "healthcheck: reinicio pendiente -> WARNING" {
  touch "${BATS_TEST_TMPDIR}/reboot-required"
  run "$HC" "${LAXOS[@]}" --fichero-reinicio "${BATS_TEST_TMPDIR}/reboot-required"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Reinicio pendiente"*"sí"* ]]
}

@test "healthcheck: fallos de SSH por encima del umbral -> WARNING" {
  local log="${BATS_TEST_TMPDIR}/auth.log"
  local i
  for i in $(seq 1 25); do
    echo "Oct  6 10:00:${i} web sshd[123${i}]: Failed password for root from 203.0.113.7 port 4${i}22 ssh2" >> "$log"
  done
  echo "Oct  6 10:01:00 web sshd[999]: Accepted publickey for miguel from 192.0.2.10 port 5000 ssh2" >> "$log"
  run "$HC" "${LAXOS[@]}" --auth-log "$log" --ssh-warn 20 --ssh-crit 100 --verbose
  [ "$status" -eq 1 ]
  [[ "$output" == *"Accesos SSH fallidos"*"25 en el log actual"* ]]
  [[ "$output" == *"203.0.113.7 (25)"* ]]
}

@test "healthcheck: servicio inexistente -> CRITICAL" {
  run "$HC" "${LAXOS[@]}" --servicios servicio-que-no-existe-xyz
  [ "$status" -eq 2 ]
  [[ "$output" == *"Servicio servicio-que-no-existe-xyz"* ]]
}

@test "healthcheck: sin systemd usa pgrep y encuentra un proceso en marcha" {
  if [[ -d /run/systemd/system ]]; then
    skip "con systemd se usa systemctl, no pgrep"
  fi
  run "$HC" "${LAXOS[@]}" --servicios bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"Servicio bash"*"en ejecución"* ]]
}

@test "healthcheck: nombre de servicio con caracteres no válidos -> 3" {
  run "$HC" --servicios 'nginx;rm'
  [ "$status" -eq 3 ]
}

@test "healthcheck: puerto esperado en escucha -> OK; ausente -> CRITICAL" {
  run "$HC" "${LAXOS[@]}" --puertos-esperados "$PUERTO_ABIERTO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Puerto ${PUERTO_ABIERTO}/tcp"*"en escucha"* ]]

  local cerrado
  cerrado=$(puerto_libre)
  run "$HC" "${LAXOS[@]}" --puertos-esperados "$cerrado"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Puerto ${cerrado}/tcp"*"no está en escucha"* ]]
}

@test "healthcheck: sin ss lee los puertos de /proc/net/tcp" {
  local falsos
  falsos=$(crear_comando_falso ss 'exit 1')
  PATH="${falsos}:${PATH}" run "$HC" "${LAXOS[@]}" --verbose --puertos-esperados "$PUERTO_ABIERTO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/proc/net/tcp"* ]]
  # El detalle agrupa los puertos por dirección: «127.0.0.1 → ..., PUERTO, ...».
  [[ "$output" == *"127.0.0.1 → "*"${PUERTO_ABIERTO}"* ]]
}

# --- Fichero de configuración ----------------------------------------------

@test "healthcheck: carga umbrales del fichero de configuración" {
  local conf="${BATS_TEST_TMPDIR}/hc.conf"
  printf '# prueba\nDISCO_AVISO=0\nDISCO_CRITICO=0   # comentario\n' > "$conf"
  run "$HC" "${LAXOS[@]}" -c "$conf"
  # Los LAXOS van en la línea de comandos y tienen prioridad: sigue OK.
  [ "$status" -eq 0 ]
  run "$HC" -c "$conf" --mem-warn 100 --mem-crit 100 --fichero-reinicio /no/existe --auth-log /dev/null
  [ "$status" -eq 2 ]
}

@test "healthcheck: el fichero de configuración no ejecuta código" {
  local conf="${BATS_TEST_TMPDIR}/hc.conf"
  local trampa="${BATS_TEST_TMPDIR}/ejecutado"
  # Las comillas simples son intencionadas: queremos el texto «$(touch ...)»
  # literal dentro del fichero, sin que se ejecute aquí.
  # shellcheck disable=SC2016
  printf 'ETIQUETA="$(touch %s)"\n' "$trampa" > "$conf"
  run "$HC" "${LAXOS[@]}" -c "$conf" --json "${BATS_TEST_TMPDIR}/r.json"
  [ ! -e "$trampa" ]
  # shellcheck disable=SC2016
  grep -qF '"etiqueta": "$(touch' "${BATS_TEST_TMPDIR}/r.json"
}

@test "healthcheck: clave desconocida en la configuración -> 3" {
  local conf="${BATS_TEST_TMPDIR}/hc.conf"
  echo "PATH=/tmp" > "$conf"
  run "$HC" -c "$conf"
  [ "$status" -eq 3 ]
  [[ "$output" == *"clave desconocida"* ]]
}

# --- Salidas -----------------------------------------------------------------

@test "healthcheck: --json genera un JSON válido y coherente con el código de salida" {
  local json="${BATS_TEST_TMPDIR}/informe.json"
  run "$HC" "${LAXOS[@]}" --mem-warn 0 --mem-crit 100 --etiqueta 'web "01" \ prueba' --json "$json"
  [ "$status" -eq 1 ]
  python3 -m json.tool "$json" > /dev/null
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["estado"], d["codigo_salida"], d["etiqueta"], len(d["comprobaciones"]) > 0)' "$json"
  [ "$output" = 'WARNING 1 web "01" \ prueba True' ]
}

@test "healthcheck: --html genera un documento y escapa los valores" {
  local html="${BATS_TEST_TMPDIR}/informe.html"
  run "$HC" "${LAXOS[@]}" --etiqueta '<script>alert(1)</script>' --html "$html"
  [ "$status" -eq 0 ]
  head -n 1 "$html" | grep -q '<!doctype html>'
  grep -qF '&lt;script&gt;alert(1)&lt;/script&gt;' "$html"
  run grep -c '<script>' "$html"
  [ "$output" = "0" ]
}

@test "healthcheck: --json en un directorio inexistente -> 3" {
  run "$HC" --json /no/existe/informe.json
  [ "$status" -eq 3 ]
}

@test "healthcheck: --nagios imprime una sola línea con datos de rendimiento" {
  run --separate-stderr "$HC" "${LAXOS[@]}" --nagios
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "HEALTHCHECK OK - "*" | "*"'Memoria'="* ]]
}

@test "healthcheck: --quiet no escribe nada en la salida estándar" {
  run --separate-stderr "$HC" "${LAXOS[@]}" --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "healthcheck: sin terminal no hay códigos de color" {
  run env -u NO_COLOR "$HC" "${LAXOS[@]}"
  [[ "$output" != *$'\e['* ]]
}
