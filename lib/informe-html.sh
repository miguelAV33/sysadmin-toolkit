# shellcheck shell=bash
#
# lib/informe-html.sh — Plantilla del informe HTML de healthcheck.sh.
#
# Separa la presentación (HTML y CSS) de la lógica de las comprobaciones.
# Genera un único fichero sin dependencias: el CSS va dentro del documento y
# no hay peticiones externas salvo las fuentes de Google Fonts (si no cargan,
# se usan las fuentes del sistema). Todo texto se escapa con escapar_html.
#
# No se usa por sí solo: lo carga healthcheck.sh, que define las variables
# globales que lee (RES_*, CONTADOR, ESTADO_GLOBAL, ETIQUETA...).
# shellcheck disable=SC2154  # esas variables se asignan en healthcheck.sh

clase_estado() {
  case $1 in
    OK)       printf 'ok' ;;
    WARNING)  printf 'warning' ;;
    CRITICAL) printf 'critical' ;;
    UNKNOWN)  printf 'unknown' ;;
    *)        printf 'info' ;;
  esac
}

html_estilos() {
  cat <<'CSS'
<style>
  :root {
    --ink: #12151d;
    --surface: #1a212d;
    --surface-2: #202836;
    --line: #2b3546;
    --text: #edf1f7;
    --text-muted: #838da0;
    --accent: #6f9bc9;
    --accent-warm: #c9a468;
    --ok: #7cc98f;
    --warning: #e0b25c;
    --critical: #e08585;
    --unknown: #838da0;
    --info: #6f9bc9;
    --font-head: "Space Grotesk", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    --font-body: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    --font-mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0;
    background: var(--ink);
    color: var(--text);
    font: 15px/1.55 var(--font-body);
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 1080px; margin: 0 auto; padding: 56px 32px 64px; }

  /* Cabecera */
  .eyebrow {
    margin: 0 0 14px;
    font: 500 12px/1 var(--font-mono);
    letter-spacing: .14em;
    text-transform: uppercase;
    color: var(--accent-warm);
  }
  h1 {
    margin: 0 0 18px;
    font: 600 clamp(30px, 5vw, 46px)/1.08 var(--font-head);
    letter-spacing: -.02em;
    overflow-wrap: anywhere;
  }
  .meta { display: flex; flex-wrap: wrap; gap: 8px; margin: 0; padding: 0; list-style: none; }
  .meta li {
    padding: 6px 12px;
    border: 1px solid var(--line);
    border-radius: 999px;
    background: var(--surface);
    color: var(--text-muted);
    font: 12.5px/1.4 var(--font-mono);
    overflow-wrap: anywhere;
  }
  .meta b { color: var(--text); font-weight: 500; }

  /* Estado global */
  .banner {
    --estado: var(--ok);
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 24px;
    align-items: center;
    margin: 36px 0 32px;
    padding: 26px 28px;
    border: 1px solid var(--line);
    border-left: 4px solid var(--estado);
    border-radius: 14px;
    background: var(--surface);
  }
  .banner.s-ok       { --estado: var(--ok);       background: linear-gradient(100deg, rgba(124,201,143,.12), var(--surface) 60%); }
  .banner.s-warning  { --estado: var(--warning);  background: linear-gradient(100deg, rgba(224,178,92,.13), var(--surface) 60%); }
  .banner.s-critical { --estado: var(--critical); background: linear-gradient(100deg, rgba(224,133,133,.14), var(--surface) 60%); }
  .banner.s-unknown  { --estado: var(--unknown);  background: linear-gradient(100deg, rgba(131,141,160,.14), var(--surface) 60%); }
  .banner .label {
    margin: 0 0 6px;
    font: 500 12px/1 var(--font-mono);
    letter-spacing: .12em;
    text-transform: uppercase;
    color: var(--text-muted);
  }
  .banner .estado {
    margin: 0 0 6px;
    font: 600 34px/1.1 var(--font-head);
    color: var(--estado);
  }
  .banner .frase { margin: 0; color: var(--text-muted); }
  .contadores { display: grid; grid-template-columns: repeat(4, minmax(72px, auto)); gap: 10px; margin: 0; }
  .contadores div {
    padding: 10px 14px;
    border: 1px solid var(--line);
    border-radius: 10px;
    background: rgba(18,21,29,.45);
    text-align: center;
  }
  .contadores dt {
    font: 500 11px/1 var(--font-mono);
    letter-spacing: .08em;
    text-transform: uppercase;
    color: var(--text-muted);
  }
  .contadores dd { margin: 6px 0 0; font: 600 24px/1 var(--font-head); }
  .contadores .critical dd { color: var(--critical); }
  .contadores .warning dd  { color: var(--warning); }
  .contadores .ok dd       { color: var(--ok); }
  .contadores .info dd     { color: var(--info); }
  .contadores .cero dd     { color: var(--text-muted); }

  /* Secciones */
  .card {
    margin: 0 0 20px;
    border: 1px solid var(--line);
    border-radius: 14px;
    background: var(--surface);
    overflow: hidden;
  }
  .card h2 {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 0;
    padding: 18px 24px;
    font: 600 18px/1.2 var(--font-head);
    letter-spacing: -.01em;
  }
  .card h2 span {
    font: 500 12px/1 var(--font-mono);
    color: var(--text-muted);
    padding: 4px 8px;
    border: 1px solid var(--line);
    border-radius: 999px;
  }
  .fila {
    display: grid;
    grid-template-columns: minmax(0, 1.25fr) minmax(0, 1.5fr) minmax(0, 1fr) 112px;
    gap: 20px;
    align-items: center;
    padding: 15px 24px;
    border-top: 1px solid var(--line);
  }
  .fila.cabecera {
    padding-top: 10px;
    padding-bottom: 10px;
    background: var(--surface-2);
    font: 500 11px/1.2 var(--font-mono);
    letter-spacing: .08em;
    text-transform: uppercase;
    color: var(--text-muted);
  }
  .nombre { display: block; font-weight: 500; overflow-wrap: anywhere; }
  .detalle { display: block; margin-top: 3px; font-size: 13px; color: var(--text-muted); overflow-wrap: anywhere; }
  .valor { font: 14px/1.45 var(--font-mono); overflow-wrap: anywhere; }
  .umbral { font: 12.5px/1.45 var(--font-mono); color: var(--text-muted); overflow-wrap: anywhere; }
  .c-estado { text-align: right; }

  /* Barra de uso con marcas en los umbrales */
  .barra {
    position: relative;
    height: 6px;
    margin-top: 9px;
    border-radius: 999px;
    background: var(--surface-2);
    box-shadow: inset 0 0 0 1px var(--line);
  }
  .barra .relleno { display: block; height: 100%; min-width: 2px; border-radius: 999px; background: var(--ok); }
  .s-warning .barra .relleno  { background: var(--warning); }
  .s-critical .barra .relleno { background: var(--critical); }
  .barra .marca { position: absolute; top: -3px; width: 2px; height: 12px; margin-left: -1px; border-radius: 1px; }
  .barra .marca.aviso   { background: rgba(224,178,92,.7); }
  .barra .marca.critico { background: rgba(224,133,133,.75); }

  /* Píldoras de estado */
  .pill {
    display: inline-block;
    min-width: 92px;
    padding: 5px 10px;
    border: 1px solid currentColor;
    border-radius: 999px;
    font: 500 12px/1.2 var(--font-mono);
    letter-spacing: .04em;
    text-align: center;
    text-transform: uppercase;
  }
  .s-ok .pill       { color: var(--ok);       background: rgba(124,201,143,.10); }
  .s-warning .pill  { color: var(--warning);  background: rgba(224,178,92,.10); }
  .s-critical .pill { color: var(--critical); background: rgba(224,133,133,.12); }
  .s-unknown .pill  { color: var(--unknown);  background: rgba(131,141,160,.10); }
  .s-info .pill     { color: var(--info);     background: rgba(111,155,201,.10); }

  footer {
    margin-top: 32px;
    padding-top: 20px;
    border-top: 1px solid var(--line);
    font: 12.5px/1.6 var(--font-mono);
    color: var(--text-muted);
  }
  footer p { margin: 0 0 4px; overflow-wrap: anywhere; }
  footer b { color: var(--accent); font-weight: 500; }

  /* Móvil: cada comprobación pasa a ser una tarjeta apilada */
  @media (max-width: 760px) {
    .wrap { padding: 32px 16px 40px; }
    .banner { grid-template-columns: minmax(0, 1fr); padding: 22px 18px; }
    .contadores { grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 6px; }
    .contadores div { padding: 9px 4px; }
    .contadores dt { font-size: 10px; letter-spacing: .04em; }
    .meta li { padding: 5px 10px; font-size: 11.5px; }
    .card h2 { padding: 16px 16px; }
    .fila.cabecera { display: none; }
    .fila {
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 6px 12px;
      padding: 14px 16px;
    }
    .c-nombre { grid-column: 1; grid-row: 1; }
    .c-estado { grid-column: 2; grid-row: 1; align-self: start; }
    .c-valor  { grid-column: 1 / -1; }
    .c-umbral { grid-column: 1 / -1; }
    .c-umbral:empty { display: none; }
    .pill { min-width: 0; }
  }
</style>
CSS
}

# Una fila del informe HTML para la comprobación de índice $1.
html_fila() {
  local i=$1
  local clase
  local barra=""
  clase=$(clase_estado "${RES_ESTADO[$i]}")

  if [[ -n "${RES_PORCENTAJE[$i]}" ]]; then
    barra="<div class=\"barra\" aria-hidden=\"true\"><span class=\"relleno\" style=\"width:$(printf '%d' "${RES_PORCENTAJE[$i]}")%\"></span>"
    # Marcas de umbral (solo si caen dentro de la barra de 0 a 100 %).
    if [[ -n "${RES_AVISO[$i]}" ]] && (( RES_AVISO[i] <= 100 )); then
      barra+="<i class=\"marca aviso\" style=\"left:$(printf '%d' "${RES_AVISO[$i]}")%\"></i>"
    fi
    if [[ -n "${RES_CRITICO[$i]}" ]] && (( RES_CRITICO[i] <= 100 )); then
      barra+="<i class=\"marca critico\" style=\"left:$(printf '%d' "${RES_CRITICO[$i]}")%\"></i>"
    fi
    barra+="</div>"
  fi

  printf '    <div class="fila s-%s">\n' "$clase"
  printf '      <div class="c-nombre"><span class="nombre">%s</span>' "$(escapar_html "${RES_NOMBRE[$i]}")"
  if [[ -n "${RES_DETALLE[$i]}" ]]; then
    printf '<span class="detalle">%s</span>' "$(escapar_html "${RES_DETALLE[$i]}")"
  fi
  printf '</div>\n'
  printf '      <div class="c-valor"><span class="valor">%s</span>%s</div>\n' \
    "$(escapar_html "${RES_VALOR[$i]}")" "$barra"
  printf '      <div class="c-umbral umbral">%s</div>\n' "$(escapar_html "${RES_UMBRAL[$i]}")"
  printf '      <div class="c-estado"><span class="pill">%s</span></div>\n' \
    "$(escapar_html "${TEXTO_ESTADO[${RES_ESTADO[$i]}]}")"
  printf '    </div>\n'
}

# Recuadro de un contador del estado global (en gris si vale 0).
html_contador() {
  local clase=$1
  local titulo=$2
  local valor=$3
  if (( valor == 0 )); then
    clase="cero"
  fi
  printf '        <div class="%s"><dt>%s</dt><dd>%d</dd></div>\n' "$clase" "$titulo" "$valor"
}

generar_html() {
  local seccion
  local i
  local total
  local frase
  local clase_global

  clase_global=$(clase_estado "$ESTADO_GLOBAL")
  case $ESTADO_GLOBAL in
    OK)       frase="Todas las comprobaciones están dentro de los umbrales." ;;
    WARNING)  frase="Hay comprobaciones que conviene revisar." ;;
    CRITICAL) frase="Hay comprobaciones que requieren atención inmediata." ;;
    *)        frase="Algunas comprobaciones no se han podido completar." ;;
  esac

  cat <<HTML
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<meta name="generator" content="healthcheck.sh ${TOOLKIT_VERSION} (sysadmin-toolkit)">
<title>Salud de $(escapar_html "$ETIQUETA") · $(escapar_html "${TEXTO_ESTADO[$ESTADO_GLOBAL]}")</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&family=Space+Grotesk:wght@500;600&display=swap">
HTML
  html_estilos
  cat <<HTML
</head>
<body>
<main class="wrap">
  <header>
    <p class="eyebrow">Informe de salud del servidor</p>
    <h1>$(escapar_html "$ETIQUETA")</h1>
    <ul class="meta">
      <li>host <b>$(escapar_html "$HOST_NOMBRE")</b></li>
      <li><b>$(escapar_html "$SO_NOMBRE")</b></li>
      <li>kernel <b>$(escapar_html "$KERNEL")</b></li>
      <li><b>$(printf '%d' "$NUCLEOS")</b> núcleos</li>
      <li>encendido <b>$(escapar_html "${TIEMPO_ENCENDIDO:-?}")</b></li>
      <li>generado <b>$(escapar_html "$FECHA_LEGIBLE")</b></li>
    </ul>
  </header>

  <section class="banner s-${clase_global}" aria-label="Estado global">
    <div>
      <p class="label">Estado global · código de salida $(printf '%d' "$CODIGO_SALIDA")</p>
      <p class="estado">$(escapar_html "${TEXTO_ESTADO[$ESTADO_GLOBAL]}")</p>
      <p class="frase">$(escapar_html "$frase")</p>
    </div>
    <dl class="contadores">
HTML
  html_contador critical "Crítico" "${CONTADOR[CRITICAL]}"
  html_contador warning "Aviso" "${CONTADOR[WARNING]}"
  html_contador ok "OK" "${CONTADOR[OK]}"
  html_contador info "Info" "${CONTADOR[INFO]}"
  printf '    </dl>\n  </section>\n'

  for seccion in "${SECCIONES[@]}"; do
    total=0
    for i in "${!RES_SECCION[@]}"; do
      if [[ "${RES_SECCION[$i]}" == "$seccion" ]]; then
        total=$(( total + 1 ))
      fi
    done
    if (( total == 0 )); then
      continue
    fi
    printf '\n  <section class="card">\n'
    printf '    <h2>%s <span>%d</span></h2>\n' "$(escapar_html "${TITULO_SECCION[$seccion]}")" "$total"
    printf '    <div class="fila cabecera" aria-hidden="true"><div>Comprobación</div><div>Valor</div><div>Umbral</div><div class="c-estado">Estado</div></div>\n'
    for i in "${!RES_SECCION[@]}"; do
      if [[ "${RES_SECCION[$i]}" == "$seccion" ]]; then
        html_fila "$i"
      fi
    done
    printf '  </section>\n'
  done

  cat <<HTML

  <footer>
    <p>Generado por <b>healthcheck.sh ${TOOLKIT_VERSION}</b> · sysadmin-toolkit · $(escapar_html "$FECHA_LEGIBLE")</p>
    <p>$(escapar_html "$(texto_resumen)")</p>
  </footer>
</main>
</body>
</html>
HTML
}
