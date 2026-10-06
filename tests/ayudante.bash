# shellcheck shell=bash
#
# tests/ayudante.bash — Funciones comunes de las pruebas (se cargan con
# «load ayudante» desde cada fichero .bats).

RAIZ="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
BIN="${RAIZ}/bin"
export RAIZ BIN

# Las pruebas comparan texto: sin colores.
export NO_COLOR=1

# Escribe en la salida un puerto TCP libre de 127.0.0.1.
puerto_libre() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# Arranca un servidor HTTP de Python en 127.0.0.1:PUERTO y espera a que
# acepte conexiones. Guarda su PID en «fichero_pid».
# «3>&-» cierra el descriptor 3 de bats: si el proceso lo heredara, bats
# esperaría a que terminase antes de acabar.
arrancar_servidor() {
  local puerto=$1
  local fichero_pid=$2
  local intento
  python3 -m http.server "$puerto" --bind 127.0.0.1 --directory "${BATS_FILE_TMPDIR}" \
    > /dev/null 2>&1 3>&- &
  echo "$!" > "$fichero_pid"
  for intento in $(seq 1 50); do
    if (exec 3<> "/dev/tcp/127.0.0.1/${puerto}") 2> /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "El servidor de pruebas no arranca (intentos: ${intento})" >&2
  return 1
}

parar_servidor() {
  local fichero_pid=$1
  if [[ -f "$fichero_pid" ]]; then
    kill "$(cat "$fichero_pid")" 2> /dev/null || true
  fi
}

# Crea un comando falso (script sh) que tapa al real si se pone delante en
# el PATH. Escribe la ruta del directorio que hay que anteponer.
crear_comando_falso() {
  local nombre=$1
  local cuerpo=$2
  local directorio="${BATS_TEST_TMPDIR}/falsos"
  mkdir -p "$directorio"
  printf '#!/bin/sh\n%s\n' "$cuerpo" > "${directorio}/${nombre}"
  chmod +x "${directorio}/${nombre}"
  printf '%s' "$directorio"
}
