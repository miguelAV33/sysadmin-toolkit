#!/usr/bin/env bats
#
# Pruebas de bin/backup.sh. Todo ocurre en directorios temporales de bats.

bats_require_minimum_version 1.5.0

setup() {
  load ayudante
  BK="${BIN}/backup.sh"
  ORIGEN="${BATS_TEST_TMPDIR}/origen"
  DESTINO="${BATS_TEST_TMPDIR}/destino"
  mkdir -p "${ORIGEN}/sub" "${ORIGEN}/cache"
  echo "contenido importante" > "${ORIGEN}/datos.txt"
  echo "línea de log" > "${ORIGEN}/sub/app.log"
  echo "temporal" > "${ORIGEN}/cache/tmp.bin"
}

# Crea copias falsas (vacías) con fechas controladas en el nombre.
crear_copias_falsas() {
  local prefijo=$1
  shift
  local fecha
  mkdir -p "$DESTINO"
  for fecha in "$@"; do
    touch "${DESTINO}/${prefijo}_${fecha}.tar.gz" "${DESTINO}/${prefijo}_${fecha}.tar.gz.sha256"
  done
}

# Lista (ordenada) de los .tar.gz que quedan en el destino.
copias_restantes() {
  find "$DESTINO" -maxdepth 1 -name '*.tar.gz' -printf '%f\n' | sort
}

# --- Ayuda y argumentos ------------------------------------------------------

@test "backup: --help muestra el uso y sale con 0" {
  run "$BK" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: backup.sh"* ]]
  [[ "$output" == *"--keep-weekly"* ]]
}

@test "backup: sin argumentos -> 2" {
  run "$BK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Falta el destino"* ]]
}

@test "backup: sin orígenes -> 2" {
  run "$BK" -d "$DESTINO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"al menos un directorio"* ]]
}

@test "backup: origen inexistente -> 2" {
  run "$BK" -d "$DESTINO" /no/existe
  [ "$status" -eq 2 ]
  [[ "$output" == *"no existe"* ]]
}

@test "backup: --keep-daily 0 -> 2 (la copia nueva no se puede borrar)" {
  run "$BK" -d "$DESTINO" --keep-daily 0 "$ORIGEN"
  [ "$status" -eq 2 ]
}

@test "backup: --keep-weekly no numérico -> 2" {
  run "$BK" -d "$DESTINO" --keep-weekly dos "$ORIGEN"
  [ "$status" -eq 2 ]
}

@test "backup: prefijo con barra -> 2" {
  run "$BK" -d "$DESTINO" -n "a/b" "$ORIGEN"
  [ "$status" -eq 2 ]
}

@test "backup: destino que es un fichero -> 2" {
  touch "${BATS_TEST_TMPDIR}/fichero"
  run "$BK" -d "${BATS_TEST_TMPDIR}/fichero" "$ORIGEN"
  [ "$status" -eq 2 ]
}

# --- Creación y verificación --------------------------------------------------

@test "backup: crea el archivo, su .sha256 válido y con permisos 600" {
  run "$BK" -d "$DESTINO" -n prueba "$ORIGEN"
  [ "$status" -eq 0 ]

  local archivo
  archivo=$(find "$DESTINO" -name 'prueba_*.tar.gz')
  [ -n "$archivo" ]
  [[ "${archivo##*/}" =~ ^prueba_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.tar\.gz$ ]]
  [ -f "${archivo}.sha256" ]
  (cd "$DESTINO" && sha256sum -c "${archivo##*/}.sha256")
  [ "$(stat -c %a "$archivo")" = "600" ]

  # El contenido se guarda con rutas relativas a «/».
  tar -tzf "$archivo" | grep -q "${ORIGEN#/}/datos.txt"
  # No quedan ficheros temporales.
  [ -z "$(find "$DESTINO" -name '*.part')" ]
}

@test "backup: --exclude deja fuera los patrones indicados" {
  run "$BK" -d "$DESTINO" -e '*.log' -e 'cache' "$ORIGEN"
  [ "$status" -eq 0 ]
  local archivo
  archivo=$(find "$DESTINO" -name 'backup_*.tar.gz')
  run tar -tzf "$archivo"
  [[ "$output" == *"datos.txt"* ]]
  [[ "$output" != *"app.log"* ]]
  [[ "$output" != *"tmp.bin"* ]]
}

@test "backup: si el destino está dentro del origen, se excluye" {
  run "$BK" -d "${ORIGEN}/copias" "$ORIGEN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"se excluye de la copia"* ]]
  run tar -tzf "$(find "${ORIGEN}/copias" -name '*.tar.gz')"
  [[ "$output" != *"copias/"* ]]
}

@test "backup: --log añade los mensajes al fichero indicado" {
  local log="${BATS_TEST_TMPDIR}/backup.log"
  run "$BK" -d "$DESTINO" --log "$log" "$ORIGEN"
  [ "$status" -eq 0 ]
  grep -q "\[OK\] backup.sh: Copia creada" "$log"
}

# --- Simulación --------------------------------------------------------------

@test "backup: --dry-run no crea el destino ni ningún fichero" {
  run "$BK" -d "$DESTINO" --dry-run --log "${BATS_TEST_TMPDIR}/sim.log" "$ORIGEN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[simulación] Se crearía el directorio"* ]]
  [ ! -e "$DESTINO" ]
  [ ! -e "${BATS_TEST_TMPDIR}/sim.log" ]
}

@test "backup: --dry-run no borra copias antiguas aunque la retención lo pida" {
  crear_copias_falsas backup 2026-01-01_020000 2026-01-02_020000 2026-01-03_020000
  local antes
  antes=$(ls -A "$DESTINO")
  run "$BK" -d "$DESTINO" --dry-run --keep-daily 1 --keep-weekly 0 "$ORIGEN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Se borraría backup_2026-01-03_020000.tar.gz"* ]]
  [ "$(ls -A "$DESTINO")" = "$antes" ]
}

# --- Retención ---------------------------------------------------------------
# Escenario: copias falsas del 1 al 20 de enero de 2026 (dos el día 20) y la
# copia real de hoy. Semanas ISO de 2026: W03 = 12-18 ene, W04 = 19-25 ene.
# Con --keep-daily 3 --keep-weekly 3 se conservan:
#   diarias:  hoy, 20 ene (la de las 23:00), 19 ene
#   semanales: semana de hoy (hoy), W04 (20 ene 23:00), W03 (18 ene, domingo)

@test "backup: la retención borra exactamente las copias que no eligen las reglas" {
  local dias=()
  local d
  for d in $(seq -w 1 20); do
    dias+=("2026-01-${d}_020000")
  done
  crear_copias_falsas backup "${dias[@]}" 2026-01-20_230000
  # Ficheros que la retención no debe tocar nunca.
  touch "${DESTINO}/otra-cosa.tar.gz" "${DESTINO}/backup_nombre-raro.tar.gz" "${DESTINO}/web_2026-01-01_020000.tar.gz"

  run "$BK" -d "$DESTINO" --keep-daily 3 --keep-weekly 3 "$ORIGEN"
  [ "$status" -eq 0 ]

  local hoy
  hoy=$(find "$DESTINO" -newer "${DESTINO}/otra-cosa.tar.gz" -name 'backup_*.tar.gz' -size +0 -printf '%f\n')
  [ -n "$hoy" ]

  run copias_restantes
  local esperado
  esperado=$(printf '%s\n' \
    backup_2026-01-18_020000.tar.gz \
    backup_2026-01-19_020000.tar.gz \
    backup_2026-01-20_230000.tar.gz \
    "$hoy" \
    backup_nombre-raro.tar.gz \
    otra-cosa.tar.gz \
    web_2026-01-01_020000.tar.gz | sort)
  [ "$output" = "$esperado" ]

  # Los .sha256 de las copias borradas también desaparecen.
  [ ! -e "${DESTINO}/backup_2026-01-17_020000.tar.gz.sha256" ]
  [ -e "${DESTINO}/backup_2026-01-18_020000.tar.gz.sha256" ]
}

@test "backup: --keep-weekly 0 deja solo las diarias" {
  crear_copias_falsas backup 2026-01-05_020000 2026-01-12_020000 2026-01-19_020000
  run "$BK" -d "$DESTINO" --keep-daily 2 --keep-weekly 0 "$ORIGEN"
  [ "$status" -eq 0 ]
  run copias_restantes
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "backup_2026-01-19_020000.tar.gz" ]
}

@test "backup: la retención solo afecta al prefijo indicado" {
  crear_copias_falsas web 2026-01-01_020000 2026-01-02_020000
  crear_copias_falsas db 2026-01-01_020000 2026-01-02_020000
  run "$BK" -d "$DESTINO" -n web --keep-daily 1 --keep-weekly 0 "$ORIGEN"
  [ "$status" -eq 0 ]
  [ ! -e "${DESTINO}/web_2026-01-01_020000.tar.gz" ]
  [ -e "${DESTINO}/db_2026-01-01_020000.tar.gz" ]
  [ -e "${DESTINO}/db_2026-01-02_020000.tar.gz" ]
}

# --- Bloqueo -----------------------------------------------------------------

@test "backup: si otra copia tiene el bloqueo -> 3 y no crea nada" {
  mkdir -p "$DESTINO"
  local bloqueo="${DESTINO}/.backup.lock"
  # Un proceso en segundo plano mantiene el bloqueo unos segundos.
  flock "$bloqueo" sleep 5 3>&- &
  local pid=$!
  # Esperamos (máximo 5 s) a que el bloqueo esté tomado.
  local espera=0
  while flock --nonblock "$bloqueo" true && (( espera < 50 )); do
    sleep 0.1
    espera=$(( espera + 1 ))
  done

  run "$BK" -d "$DESTINO" "$ORIGEN"
  kill "$pid" 2> /dev/null || true
  [ "$status" -eq 3 ]
  [[ "$output" == *"Ya hay una copia en curso"* ]]
  [ -z "$(find "$DESTINO" -name '*.tar.gz*')" ]
}

# --- Interrupción ------------------------------------------------------------

@test "backup: una señal TERM detiene tar al momento, borra el .part y sale con 143" {
  # 96 MiB aleatorios (no se comprimen): gzip tarda lo bastante como para
  # interrumpir la copia a medias.
  head -c 96M /dev/urandom > "${ORIGEN}/aleatorio.bin"
  "$BK" -d "$DESTINO" "$ORIGEN" 3>&- &
  local pid=$!

  # Esperamos (máximo 5 s) a que aparezca el fichero .part.
  local espera=0
  until compgen -G "${DESTINO}/*.part" > /dev/null || (( espera >= 50 )); do
    sleep 0.1
    espera=$(( espera + 1 ))
  done
  kill -TERM "$pid"

  local codigo=0
  wait "$pid" || codigo=$?
  [ "$codigo" -eq 143 ]
  [ -z "$(find "$DESTINO" -name '*.part' -o -name '*.tar.gz')" ]
}
