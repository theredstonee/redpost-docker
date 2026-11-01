#!/usr/bin/env bash
# RedPost — Installation auf einem Linux-Server (Debian/Ubuntu, auch RHEL-Verwandte).
# One-liner / Einzeiler (installs to /opt/redpost, other folder: RP_DIR=/path):
#   curl -fsSL https://raw.githubusercontent.com/theredstonee/redpost-docker/main/install.sh | sudo bash
# Oder im Ordner mit den Dateien:  sudo bash install.sh
# Entfernen / Uninstall:  sudo bash /opt/redpost/install.sh --uninstall
#
# Zwei Wege nach aussen, der Installer erkennt selbst, welcher passt:
#   Caddy  — Port 80/443 sind frei: eigener Caddy mit automatischem HTTPS (Let's Encrypt).
#   Port   — Port 80/443 sind schon belegt (nginx, Apache, Plesk …): die App bekommt einen freien
#            Port auf 127.0.0.1, dein Webserver bekommt einen Virtual Host fuer die Domain.
#
# Schalter (optional):  --lang en|de  --port 8080  --domain drop.firma.de  --email du@firma.de
#                       --caddy (Caddy erzwingen)  --no-vhost (keinen Virtual Host anlegen)
#                       --webserver=nginx|apache|keiner (kein nginx/Apache da: diesen ohne Frage installieren,
#                         samt Virtual Host + HTTPS per certbot; ohne Terminal und ohne Schalter nur die Vorlage)
#                       --uninstall / --deinstallieren (Container, Webserver-Eintraege, auf Wunsch alle Daten)
#                       --nur-vhost --domain d --webserver nginx|apache (nur Webserver + Virtual Host + HTTPS fuer eine
#                         bestehende Installation im Port-Modus, ohne Fragen; ruft der Update-Dienst fuer den Assistenten auf)
# Ein zweiter Aufruf aktualisiert nur (Image ziehen, neu starten) und fragt nichts mehr.
# Nur aktualisieren (nichts neu einrichten, keine Fragen):
#   curl -fsSL https://raw.githubusercontent.com/theredstonee/redpost-docker/main/update.sh | sudo bash
set -euo pipefail
QUELLE="${RP_QUELLE:-https://raw.githubusercontent.com/theredstonee/redpost-docker/main}"   # RP_QUELLE nur fuer Tests
DATEIEN="docker-compose.yml compose.caddy.yml compose.port.yml compose.node.yml compose.mail.yml compose.mail-caddy.yml compose.mail-le.yml radicale.conf Caddyfile install.sh update.sh .env.example README.md version.json"
# Unraid: ausser /boot (USB-Stick) und /mnt (Array/Cache) liegt alles im Arbeitsspeicher — nach einem Neustart waeren
# Compose-Dateien und .env weg (die Datenbank im Docker-Volume bleibt, passt dann aber nicht mehr zu einer neuen .env).
# Darum gehoert die Installation dort nach /mnt/user/appdata/<Ordnername>: gleicher Name → gleicher Compose-Projektname
# → dieselben Volumes. unraid_ziel <ordner> gibt den dauerhaften Ordner aus, wenn <ordner> im Arbeitsspeicher liegt.
unraid_ziel() {
  [ -f /etc/unraid-version ] && [ -d /mnt/user ] || return 1
  case "$1" in /mnt/*|/boot/*) return 1 ;; esac
  printf '%s' "/mnt/user/appdata/$(basename "$1")"
}
# unraid_umziehen <alt> <neu> — Ordner kopieren, Dienst + Zeitplan auf den neuen Ordner umstellen, alten beiseitelegen.
# Die laufenden Container bleiben, bis sie aus dem neuen Ordner neu gestartet werden (Update/Installation tun das).
unraid_umziehen() {
  local alt="$1" neu="$2" a f
  [ -f "$alt/docker-compose.yml" ] || return 1
  if [ -e "$neu" ] && [ -n "$(ls -A "$neu" 2>/dev/null)" ]; then return 1; fi
  mkdir -p "$neu" && cp -a "$alt/." "$neu/" || { rm -rf "$neu"; return 1; }
  a=$(printf '%s' "$alt" | sed 's/[][\.*^$#]/\\&/g')
  for f in /usr/local/bin/redpost-update /boot/config/plugins/redpost/redpost-update /boot/config/plugins/dynamix/redpost-update.cron /etc/cron.d/root; do
    [ -f "$f" ] && sed -i "s#\\([=\"' ]\\)$a\\([/\"';]\\|\$\\)#\\1$neu\\2#g" "$f"
  done
  if [ -x /usr/local/sbin/update_cron ]; then /usr/local/sbin/update_cron >/dev/null 2>&1 || true; fi
  mv "$alt" "$alt.umgezogen-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  return 0
}
# inst_suchen — vorhandene RedPost-Installation(en) finden, auch mit anderem Ordnernamen oder an ungewoehnlichem Ort.
# Docker Compose merkt sich den Ordner jeder Installation im Container-Label. Vorrang: laufende Installationen, dann
# gestoppte, erst danach Ordner auf der Platte mit einer docker-compose.yml fuer unser Image. Ein Ordner pro Zeile.
inst_echt() { # inst_echt <ordner> — nur Ordner, deren COMPOSE_FILE ausschliesslich mitgelieferte Dateien nennt (Test-/Eigenbau-Umgebungen nie uebernehmen)
  local cf x
  cf=$(sed -n 's/^COMPOSE_FILE=//p' "$1/.env" 2>/dev/null | tail -1 | tr -d '"'"'"'\r')
  [ -n "$cf" ] || return 0
  for x in $(printf '%s' "$cf" | tr ':' ' '); do
    case "$x" in docker-compose.yml|compose.caddy.yml|compose.port.yml|compose.node.yml|compose.mail.yml|compose.mail-caddy.yml|compose.mail-le.yml) ;; *) return 1 ;; esac
  done
}
inst_ordner() { # inst_ordner <docker-ps-Schalter …> — Ordner der passenden App-Container
  local c d img
  command -v docker >/dev/null 2>&1 || return 0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    img=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || true)
    case "$img" in *theredstonee/redpost:*|*theredstonee/redpost) ;; *) continue ;; esac
    d=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$c" 2>/dev/null || true)
    [ -n "$d" ] && [ -f "$d/docker-compose.yml" ] && [ -f "$d/.env" ] && inst_echt "$d" && printf '%s\n' "$d"
  done < <(docker ps "$@" -q --filter label=com.docker.compose.service=app 2>/dev/null)
}
inst_suchen() {
  local f d t
  t=$(inst_ordner | awk 'NF && !s[$0]++'); [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
  t=$(inst_ordner -a | awk 'NF && !s[$0]++'); [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
  while IFS= read -r f; do
    case "$f" in */.sicherung/*|*.umgezogen-*|*/.trash*) continue ;; esac
    grep -q 'theredstonee/redpost:' "$f" 2>/dev/null || continue
    grep -q 'theredstonee/redclub:' "$f" 2>/dev/null && continue   # RedClub mit eingebautem RedPost
    d=$(dirname "$f"); [ -f "$d/.env" ] && inst_echt "$d" && printf '%s\n' "$d"
  done < <(find /opt /srv /root /home /mnt/user/appdata /mnt/cache/appdata /docker /data -maxdepth 3 -name docker-compose.yml 2>/dev/null) | awk 'NF && !s[$0]++'
}
# --nur-vhost (vom Update-Dienst): nur im Ordner der Installation (RP_DIR) arbeiten — nichts suchen, umziehen oder laden
NUR_VHOST=""
for a in "$@"; do [ "$a" = "--nur-vhost" ] && NUR_VHOST="ja"; done
if [ -n "$NUR_VHOST" ]; then
  v_dir="${RP_DIR:-$(dirname "$0")}"
  [ -f "$v_dir/docker-compose.yml" ] && [ -f "$v_dir/.env" ] || { echo "FEHLER: --nur-vhost braucht RP_DIR mit einer RedPost-Installation / ERROR: --nur-vhost needs RP_DIR with a RedPost installation"; exit 1; }
  cd "$v_dir"
fi
GEFUNDEN=""
if [ -z "$NUR_VHOST" ] && [ -z "${RP_DIR:-}" ] && ! { [ -f "$0" ] && [ -f "$(dirname "$0")/docker-compose.yml" ]; }; then
  g_alle=$(inst_suchen 2>/dev/null || true)
  case "$(printf '%s\n' "$g_alle" | grep -c . || true)" in
    0) ;;
    1) GEFUNDEN="$g_alle"; echo "==> RedPost: vorhandene Installation gefunden / existing installation found: $GEFUNDEN" ;;
    *) echo "==> Mehrere RedPost-Installationen gefunden / several installations found:"; printf '      %s\n' $g_alle
       echo "    Bitte die richtige waehlen / please pick one: curl -fsSL $QUELLE/install.sh | sudo RP_DIR=/pfad bash"; exit 1 ;;
  esac
fi
UNRAID_ZIEL=""
if [ -z "$NUR_VHOST" ] && [ -z "${RP_DIR:-}" ] && [ -f /etc/unraid-version ] && [ -d /mnt/user ]; then
  UNRAID_ZIEL="/mnt/user/appdata/redpost"
  u_hier=""; if [ -f "$0" ] && [ -f "$(dirname "$0")/docker-compose.yml" ]; then u_hier="$(cd "$(dirname "$0")" && pwd)"; fi
  u_alt="${u_hier:-${GEFUNDEN:-/opt/redpost}}"
  if u_neu=$(unraid_ziel "$u_alt") && [ -f "$u_alt/docker-compose.yml" ]; then
    if unraid_umziehen "$u_alt" "$u_neu"; then
      echo "==> Unraid: $u_alt -> $u_neu (übersteht Neustarts / survives reboots)"
      UNRAID_ZIEL="$u_neu"; [ -n "$GEFUNDEN" ] && GEFUNDEN="$u_neu"
      if [ -n "$u_hier" ]; then
        cd "$u_neu"
        if { true </dev/tty; } 2>/dev/null; then exec bash ./install.sh "$@" </dev/tty; else exec bash ./install.sh "$@"; fi
      fi
    else
      echo "==> Unraid: $u_alt liegt im Arbeitsspeicher, $u_neu ist schon belegt — bitte selbst umziehen / in RAM, $u_neu is taken — please move it yourself"
      UNRAID_ZIEL=""
    fi
  fi
fi
# Ueber curl | bash gestartet (oder Dateien fehlen): alles nach /opt/redpost (Unraid: /mnt/user/appdata/redpost) holen und dort weitermachen
if [ -n "$NUR_VHOST" ]; then
  :   # schon oben in RP_DIR gewechselt
elif [ -f "$0" ] && [ -f "$(dirname "$0")/docker-compose.yml" ]; then
  cd "$(dirname "$0")"
else
  ZIEL="${RP_DIR:-${GEFUNDEN:-${UNRAID_ZIEL:-/opt/redpost}}}"
  echo "==> RedPost: $ZIEL"
  mkdir -p "$ZIEL" && cd "$ZIEL"
  for f in $DATEIEN; do curl -fsSL -o "$f" "$QUELLE/$f" || { [ "$f" = "version.json" ] || { echo "ERROR: $f"; exit 1; }; }; done
  # Fragen brauchen das Terminal (stdin ist bei curl | bash die Leitung) — ohne Terminal gelten die Vorgaben
  # Rest des Skripts aus der curl-Leitung leer lesen: exec schliesst sie sonst, waehrend curl noch schreibt
  # (Meldung „curl: (23) Failure writing output to destination“ am Ende, obwohl alles geklappt hat)
  [ -t 0 ] || cat >/dev/null 2>&1 || true
  if { true </dev/tty; } 2>/dev/null; then exec bash ./install.sh "$@" </dev/tty; else exec bash ./install.sh "$@"; fi
fi

PORT=""; DOMAIN=""; EMAIL=""; MODUS=""; VHOST="ja"; WS_WAHL=""; WEG=""; SPR=""; NUR_DIENST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) SPR="${2,,}"; shift 2 ;;
    --port) PORT="$2"; MODUS="port"; shift 2 ;;
    --domain) DOMAIN="${2,,}"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --caddy) MODUS="caddy"; shift ;;
    --no-vhost) VHOST="nein"; shift ;;
    --webserver|--webserver=*)   # kein nginx/Apache da: diesen installieren (ohne Frage)
      if [ "$1" = "--webserver" ]; then WS_WAHL="${2:-}"; shift $(( $# > 1 ? 2 : 1 )); else WS_WAHL="${1#*=}"; shift; fi
      WS_WAHL="${WS_WAHL,,}"
      case "$WS_WAHL" in nginx|apache|apache2|httpd|keiner|none) ;; *) echo "--webserver: nginx | apache | keiner (none)"; exit 1 ;; esac ;;
    --dienst) NUR_DIENST="ja"; shift ;;
    --nur-vhost) shift ;;                 # oben schon erkannt (NUR_VHOST)   # nur den Update-Dienst neu einrichten (ruft update.sh auf)
    --deinstallieren|--uninstall) WEG="ja"; shift ;;
    *) echo "Unknown option / Unbekannter Schalter: $1"; exit 1 ;;
  esac
done

# Aussehen: Farben nur im Terminal (RP_FARBE=1 erzwingt sie, NO_COLOR/TERM=dumb schaltet sie ab), Zeichen nur mit UTF-8
if { [ -t 1 ] || [ -n "${RP_FARBE:-}" ]; } && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  R=$'\033[38;2;232;48;48m'; R2=$'\033[38;2;255;110;100m'; G=$'\033[38;2;74;222;128m'; Y=$'\033[38;2;251;191;36m'
  C=$'\033[38;2;125;211;252m'; D=$'\033[2m'; B=$'\033[1m'; U=$'\033[4m'; N=$'\033[0m'
else R=""; R2=""; G=""; Y=""; C=""; D=""; B=""; U=""; N=""; fi
if locale charmap 2>/dev/null | grep -qi 'utf-\?8' || echo "${LANG:-}${LC_ALL:-}" | grep -qi 'utf-\?8'; then
  Z_SCHRITT="▸"; Z_OK="✔"; Z_FEHLER="✖"; Z_FRAGE="?"; Z_PUNKT="·"; K_OL="╭"; K_OR="╮"; K_UL="╰"; K_UR="╯"; K_H="─"; K_V="│"; SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
  Z_SCHRITT=">"; Z_OK="OK"; Z_FEHLER="X"; Z_FRAGE="?"; Z_PUNKT="-"; K_OL="+"; K_OR="+"; K_UL="+"; K_UR="+"; K_H="-"; K_V="|"; SPIN=('|' '/' '-' '\')
fi
# --nur-vhost schreibt ins Live-Protokoll des Assistenten: Schritte dort immer als „==> …“
if [ -n "$NUR_VHOST" ]; then Z_SCHRITT="==>"; Z_OK="==>"; Z_FEHLER="==>"; fi
VERSION_TXT=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' version.json 2>/dev/null | head -1 || true)
banner() {
  echo ""
  printf '%s\n' "${R}${B}   ██████╗ ███████╗██████╗ ${R2}██████╗  ██████╗ ███████╗████████╗${N}" \
                "${R}${B}   ██╔══██╗██╔════╝██╔══██╗${R2}██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝${N}" \
                "${R}${B}   ██████╔╝█████╗  ██║  ██║${R2}██████╔╝██║   ██║███████╗   ██║   ${N}" \
                "${R}${B}   ██╔══██╗██╔══╝  ██║  ██║${R2}██╔═══╝ ██║   ██║╚════██║   ██║   ${N}" \
                "${R}${B}   ██║  ██║███████╗██████╔╝${R2}██║     ╚██████╔╝███████║   ██║   ${N}" \
                "${R}${B}   ╚═╝  ╚═╝╚══════╝╚═════╝ ${R2}╚═╝      ╚═════╝ ╚══════╝   ╚═╝   ${N}"
  echo "   ${D}Selbst gehostete E-Mail ${Z_PUNKT} self-hosted e-mail${N}"
  echo "   ${D}${VERSION_TXT:+v$VERSION_TXT  ${Z_PUNKT}  }by TheRedStonee ${Z_PUNKT} https://www.theredstonee.de/redpost/${N}"
  echo ""
}
# Kasten um wichtige Werte (Setup-Code, Adresse): kasten FARBE "Zeile" ["Zeile" …]
kasten() {
  local farbe="$1"; shift
  local breit=0 z
  for z in "$@"; do [ ${#z} -gt $breit ] && breit=${#z}; done
  local linie; linie=$(printf "%$((breit + 4))s" "" | sed "s/ /${K_H}/g")
  echo "  ${farbe}${K_OL}${linie}${K_OR}${N}"
  # von Hand auffuellen: printf zaehlt Bytes, ${#z} Zeichen (Umlaute, „·“)
  for z in "$@"; do printf '  %s%s%s  %s%s%s%*s  %s%s%s\n' "$farbe" "$K_V" "$N" "$B" "$z" "$N" $((breit - ${#z})) "" "$farbe" "$K_V" "$N"; done
  echo "  ${farbe}${K_UL}${linie}${K_UR}${N}"
}
[ -n "${RP_KEIN_BANNER:-}" ] || banner

# Sprache: Schalter → .env → fragen (Standard Englisch)
[ -n "$SPR" ] || SPR=$(sed -n 's/^RP_LANG=//p' .env 2>/dev/null | tail -1 || true)
if [ "$SPR" != "de" ] && [ "$SPR" != "en" ]; then
  SPR="en"
  if [ -t 0 ]; then
    echo ""
    echo "  ${Y}${Z_FRAGE}${N} ${B}Language / Sprache:${N}   ${C}1${N}) English   ${C}2${N}) Deutsch"
    read -r -p "    [1] " wahl </dev/tty || true
    case "${wahl:-1}" in 2|de|d|deutsch|Deutsch) SPR="de" ;; esac
  fi
fi
s() { if [ "$SPR" = "de" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }   # s "deutsch" "english"
say() { # Meldung je Art einfaerben: „==> Fertig/Done“ gruen, „==> “ Schritt, FEHLER/ERROR rot, eingerueckt = Detail
  local m; m=$(s "$1" "$2")
  m=$(printf '%s' "$m" | sed -E "s#(https?://[^ )\"']+)#${C}${U}\1${N}#g")
  case "$m" in
    "==> Fertig"*|"==> Done"*) echo ""; echo "${G}${B}${Z_OK} ${m#==> }${N}" ;;
    "==> "*) echo "${R}${B}${Z_SCHRITT}${N} ${B}${m#==> }${N}" ;;
    FEHLER:*|ERROR:*) echo "${R}${B}${Z_FEHLER} ${m}${N}" ;;
    "    FEHLER"*|"    ERROR"*) echo "  ${R}${Z_FEHLER}${N} ${m#    }" ;;
    "    "*) echo "  ${D}${K_V}${N} ${m#    }" ;;
    *) echo "$m" ;;
  esac
}

# Zum Testen: RP_DRY_RUN=1 zeigt Aenderungen am Webserver nur an, statt sie auszufuehren.
tu() { if [ "${RP_DRY_RUN:-}" = "1" ]; then echo "    ($(s Probelauf "dry run")) $*"; else "$@"; fi; }
frage() { # frage "Text" "Vorgabe" -> Antwort (ohne Terminal: Vorgabe)
  local antwort=""
  local text="$1"; text="${text#==> }"; text="${text#    }"
  if [ -t 0 ]; then read -r -p "  ${Y}${Z_FRAGE}${N} ${text} ${D}[$2]${N} " antwort </dev/tty || true; fi
  echo "${antwort:-$2}"
}
ja() { # ja "Text" "j|n" -> 0 bei ja (akzeptiert j/ja/y/yes)
  local vorgabe="$2" a
  [ "$SPR" = "en" ] && { [ "$vorgabe" = "j" ] && vorgabe="y"; }
  a=$(frage "$1 ($(s j/n y/n))" "$vorgabe"); case "${a,,}" in j|ja|y|yes) return 0 ;; *) return 1 ;; esac
}
belegt() { # lauscht etwas auf dem Port?
  if command -v ss >/dev/null 2>&1; then ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
  else (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}
wer_lauscht() { ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//'; }

# Deinstallieren: Container weg, Webserver-Eintraege weg (mit Backup), auf Wunsch auch alle Daten und der Ordner
if [ -n "$WEG" ]; then
  say "==> RedPost entfernen (Ordner: $PWD)" "==> Removing RedPost (folder: $PWD)"
  daten="nein"
  if ja "    $(s "Auch ALLE Mails, Kalender, Kontakte und die Datenbank loeschen? Das laesst sich nicht rueckgaengig machen." "Also delete ALL e-mails, calendars, contacts and the database? This cannot be undone.")" "n"; then
    wort=$(s loeschen delete)
    bestaetigt=$(frage "    $(s "Zur Bestaetigung bitte  $wort  eintippen" "To confirm, please type  $wort")" "")
    [ "$bestaetigt" = "$wort" ] && daten="ja" || say "    Nicht bestaetigt — Mails und Datenbank bleiben erhalten." "    Not confirmed — e-mails and database are kept."
  fi
  if [ -f docker-compose.yml ] && command -v docker >/dev/null 2>&1; then
    if [ "$daten" = "ja" ]; then docker compose down -v --remove-orphans || true; else docker compose down --remove-orphans || true; fi
    docker image rm ghcr.io/theredstonee/redpost:latest >/dev/null 2>&1 || true
  fi
  # Update-Dienst
  rm -f /etc/cron.d/redpost-update
  if [ -f /etc/systemd/system/redpost-update.path ]; then
    systemctl disable --now redpost-update.path redpost-update.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/redpost-update.path /etc/systemd/system/redpost-update.service /etc/systemd/system/redpost-update.timer /usr/local/bin/redpost-update
    systemctl daemon-reload || true
  fi
  # Unraid: Dienst + Zeitplan auf dem USB-Stick
  if [ -d /boot/config/plugins/redpost ]; then
    rm -rf /boot/config/plugins/redpost /boot/config/plugins/dynamix/redpost-update.cron /usr/local/bin/redpost-update
    [ -x /usr/local/sbin/update_cron ] && /usr/local/sbin/update_cron >/dev/null 2>&1
  fi
  stempel=$(date +%Y%m%d-%H%M%S); neu_laden=""
  for datei in /etc/nginx/sites-enabled/redpost.conf /etc/nginx/sites-enabled/redpost-setup.conf /etc/nginx/sites-available/redpost.conf /etc/nginx/sites-available/redpost-setup.conf \
               /etc/nginx/conf.d/redpost.conf /etc/nginx/conf.d/redpost-setup.conf /etc/apache2/sites-enabled/redpost.conf /etc/apache2/sites-enabled/redpost-setup.conf \
               /etc/apache2/sites-available/redpost.conf /etc/apache2/sites-available/redpost-setup.conf /etc/httpd/conf.d/redpost.conf /etc/httpd/conf.d/redpost-setup.conf \
               /etc/apache2/sites-enabled/redpost-le-ssl.conf /etc/apache2/sites-available/redpost-le-ssl.conf /etc/httpd/conf.d/redpost-le-ssl.conf; do
    if [ -L "$datei" ]; then rm -f "$datei"; neu_laden="ja"
    elif [ -f "$datei" ]; then mkdir -p /root/redpost-backup && cp -a "$datei" "/root/redpost-backup/$(basename "$datei").bak-$stempel" && rm -f "$datei"; neu_laden="ja"; fi
  done
  if [ -n "$neu_laden" ]; then
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || systemctl start nginx 2>/dev/null || nginx || pkill -HUP -o -x nginx; fi
    if command -v apache2ctl >/dev/null 2>&1 && apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 2>/dev/null || apache2ctl graceful || true; fi
    if ! command -v apache2ctl >/dev/null 2>&1 && command -v httpd >/dev/null 2>&1 && httpd -t >/dev/null 2>&1; then systemctl reload httpd 2>/dev/null || httpd -k graceful || true; fi
    say "==> Webserver-Eintraege entfernt (Sicherung in /root/redpost-backup)." "==> Web server entries removed (backup in /root/redpost-backup)."
  fi
  dom=$(sed -n 's/^RP_PROXY_DOMAIN=//p' .env 2>/dev/null | tail -1 || true)
  if [ -n "$dom" ] && command -v certbot >/dev/null 2>&1 && certbot certificates 2>/dev/null | grep -q "Certificate Name: $dom$"; then
    ja "    $(s "Zertifikat fuer $dom auch loeschen?" "Also delete the certificate for $dom?")" "n" && certbot delete --cert-name "$dom" -n || true
  fi
  if [ "$daten" = "ja" ]; then
    ordner="$PWD"; cd /
    if ja "    $(s "Ordner $ordner auch loeschen (inkl. .env)?" "Also delete the folder $ordner (incl. .env)?")" "j"; then rm -rf "$ordner"; say "==> Ordner entfernt." "==> Folder removed."; fi
    say "==> RedPost ist vollstaendig entfernt." "==> RedPost has been removed completely."
  else
    say "==> Container gestoppt und entfernt. Mails, Datenbank und dieser Ordner sind noch da —" "==> Containers stopped and removed. E-mails, database and this folder are still there —"
    say "    neu starten mit  sudo bash install.sh  (gleiches Datenbank-Passwort aus der .env)." "    start again with  sudo bash install.sh  (same database password from .env)."
  fi
  exit 0
fi

# Symlink-sichere Schreibzugriffe von root in den Datenordner der App (gehoert dem App-Nutzer im Container).
# Stehen per declare -f auch woertlich im Update-Dienst (siehe deploy/einbetten.py) — nur EINE Fassung.
# sicher_ordner <ordner> — 0, wenn <ordner> ein echter Ordner ist und kein Link (auch nicht im letzten Glied):
# physischer Pfad == physischer Pfad des Elternordners + Name.
sicher_ordner() {
  local d="${1%/}" p
  [ -d "$d" ] && [ ! -L "$d" ] || return 1
  p=$(cd -P "${d%/*}/" 2>/dev/null && pwd) || return 1
  [ "$(cd -P "$d" 2>/dev/null && pwd)" = "${p%/}/${d##*/}" ]
}
# ablegen <pfad> — stdin als <pfad> ablegen (644), ohne je einem Link zu folgen: neue Datei mit O_EXCL (set -C)
# im Ordner selbst (cd: ein danach vertauschter Ordner aendert nichts), dann umbenennen (folgt keinem Link).
ablegen() {
  local d="${1%/*}" n="${1##*/}"
  sicher_ordner "$d" || return 1
  ( cd -P "$d" || exit 1
    t=".neu.$$.$RANDOM$RANDOM"
    ( umask 022; set -C; cat > "$t" ) 2>/dev/null || exit 1
    mv -fT "$t" "$n" 2>/dev/null || { rm -f "$n"; mv -f "$t" "$n"; } )
}
# log_oeffnen <pfad> <fd> — <pfad> frisch anlegen (644) und in EINEM Schritt (O_EXCL) auf Kanal <fd> oeffnen;
# danach nur noch ueber /dev/fd/<fd> schreiben und lesen. Beispiel:  log_oeffnen "$DATEN/.update.log" 6 && LOG=/dev/fd/6
log_oeffnen() {
  local d="${1%/*}" n="${1##*/}" t alt="$PWD" um rc=1 c=""
  case "$2" in [3-9]) ;; *) return 1 ;; esac
  sicher_ordner "$d" || return 1
  cd -P "$d" || return 1
  t=".neu.$$.$RANDOM$RANDOM"; um=$(umask); umask 022
  case "$-" in *C*) c=1 ;; esac
  set -C
  if eval "exec $2>\"\$t\"" 2>/dev/null; then rc=0; fi
  # gleich im Anhaenge-Modus neu oeffnen — ueber den Kanal selbst (dieselbe Datei), nicht ueber den Pfad
  if [ "$rc" = 0 ]; then eval "exec $2>>/dev/fd/$2" 2>/dev/null || true; fi
  [ -n "$c" ] || set +C; umask "$um"
  if [ "$rc" = 0 ]; then mv -fT "$t" "$n" 2>/dev/null || { rm -f "$n"; mv -f "$t" "$n"; }; fi
  cd "$alt" 2>/dev/null || true
  return "$rc"
}
# auftrags_ordner <daten> — .anfragen/ und .status/ als echte Ordner der App (uid 1000). Ein dort untergeschobener
# Link (oder eine Datei) wird entfernt, nie verfolgt (chown -h aendert hoechstens den Link selbst).
auftrags_ordner() {
  local o p
  for o in .anfragen .status; do
    p="$1/$o"
    if [ -L "$p" ] || { [ -e "$p" ] && [ ! -d "$p" ]; }; then rm -f "$p"; fi
    mkdir -p "$p" 2>/dev/null || true; chown -h 1000:1000 "$p" 2>/dev/null || true
  done
  return 0
}

# 5b. Update-Dienst: der Knopf „Jetzt aktualisieren“ im Panel legt eine Anfrage-Datei in /data ab, ein
#     systemd-Pfad-Dienst auf dem Server zieht dann das neue Image und startet die App neu. So braucht
#     RedPost selbst keinen Zugriff auf Docker.
updater_einrichten() {
  DIENST_GRUND=""
  local app daten
  app=$(docker compose ps -q app 2>/dev/null || true)
  [ -n "$app" ] || { DIENST_GRUND="$(s "Der App-Container laeuft nicht (docker compose ps app ist leer)." "The app container is not running (docker compose ps app is empty).")"; return 1; }
  daten=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$app" 2>/dev/null || true)
  # Docker als Snap: docker inspect nennt /var/lib/docker/…, auf dem Server liegt es unter /var/snap/docker/common/var-lib-docker/…
  if [ -n "$daten" ] && [ ! -d "$daten" ] && [ -d "/var/snap/docker/common/var-lib-docker${daten#/var/lib/docker}" ]; then daten="/var/snap/docker/common/var-lib-docker${daten#/var/lib/docker}"; fi
  [ -n "$daten" ] && [ -d "$daten" ] || { DIENST_GRUND="$(s "Der Datenordner der App ($daten) ist vom Server aus nicht lesbar (Docker rootless oder in einer VM?)." "The app data folder ($daten) is not readable from the server (rootless Docker or inside a VM?).")"; return 1; }
# >>> DIENST (aus deploy/dienst.sh, eingebettet von deploy/einbetten.py — hier nicht von Hand aendern)
  { printf '#!/usr/bin/env bash\n# RedPost — Update-Dienst (angelegt von install.sh; systemd: redpost-update.path)\n'
    printf 'DIR=%q\nDATEN=%q\nQUELLE=%q\n' "$PWD" "$daten" "$QUELLE"
    declare -f ws_info sicher_ordner ablegen log_oeffnen auftrags_ordner   # dieselben Fassungen wie in install.sh
    cat <<'SKRIPT'
# RedPost — Update-Dienst (Stand 5). install.sh schreibt diese Datei nach /usr/local/bin/redpost-update und setzt
# davor DIR (Installationsordner), DATEN (Daten-Volume der App auf dem Server) und QUELLE (Download-Adresse).
#
# Die App legt Auftraege als JSON in $DATEN/.anfragen/ ab (alte Apps: eine Datei $DATEN/.update-anfrage).
# Jeder Auftrag hat eine id; das Ergebnis steht danach in $DATEN/.status/<id>.json (dazu fuer alte Apps die
# bisherigen Sammeldateien .update-status und .tunnel-status).
# Es gibt nur die festen Aktionen unten — der Dienst fuehrt nie Befehle aus der Anfrage aus.
# ws_info (Webserver-Erkennung) und die Schreib-Helfer sicher_ordner/ablegen/log_oeffnen/auftrags_ordner setzt install.sh davor (seine eigene Fassung,
# siehe einbetten.py). Der Datenordner gehoert dem App-Nutzer (Container), dieser Dienst laeuft als root: dort NIE
# durch einen Pfad schreiben, lesen oder chown/chmod-en, unter dem die App einen Link untergeschoben haben koennte.
set -uo pipefail
umask 022
# cron (z. B. Unraid) startet mit sehr kurzem PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
for f in sicher_ordner ablegen log_oeffnen auftrags_ordner; do
  declare -F "$f" >/dev/null || { echo "redpost-update: $f fehlt — install.sh --dienst erneut ausfuehren" >&2; exit 1; }
done
# die App (uid 1000) muss Auftraege ablegen und Status lesen koennen
auftrags_ordner "$DATEN"
# Nichts zu tun (cron/Zeitgeber schauen jede Minute nach): sofort fertig, ohne auf die Sperre zu warten
[ -n "$(ls -A "$DATEN/.anfragen" 2>/dev/null)" ] || [ -f "$DATEN/.update-anfrage" ] || [ -L "$DATEN/.update-anfrage" ] || exit 0
# Immer nur ein Lauf (systemd-Ausloeser + cron koennen sich ueberschneiden): der zweite wartet
if command -v flock >/dev/null 2>&1; then exec 9>/run/redpost-update.lock 2>/dev/null || exec 9>/tmp/redpost-update.lock; flock -w 3600 9 || exit 0; fi
# Uebrig gebliebene Teil-Dateien (App beim Schreiben abgestuerzt) halten den Ordner sonst ewig „nicht leer“
find "$DATEN/.anfragen" -mindepth 1 -maxdepth 1 ! -name '*.json' -mmin +2 -delete 2>/dev/null
# Hat systemd die Ueberwachung schon abgeschaltet (zu viele Starts), wieder einschalten
if command -v systemctl >/dev/null 2>&1 && systemctl is-failed -q redpost-update.path 2>/dev/null; then systemctl reset-failed redpost-update.path redpost-update.service 2>/dev/null; systemctl start redpost-update.path 2>/dev/null; fi
# Docker-Befehle duerfen nicht ewig haengen: nach 20 Minuten abbrechen. Laeuft ein Auftrag (LOG gesetzt), geht die
# Ausgabe zusaetzlich live ins Protokoll .status/<id>.log.
LOG=""
_docker() { if command -v timeout >/dev/null 2>&1; then timeout 1200 docker "$@"; else command docker "$@"; fi; }
docker() { if [ -n "$LOG" ]; then _docker "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; fi; _docker "$@"; }
notiz() { [ -n "$LOG" ] && printf '==> %s\n' "$1" >> "$LOG"; return 0; }

feld() { sed -n "s#.*\"$1\":\"\\([$2]*\\)\".*#\\1#p" "$3" | head -1; }
schreib() { # schreib <id> <alte Sammeldatei> <status> <meldung>
  local z m; z=$(date -Is); m=$(printf '%s' "$4" | tr '\n"\\' '   ' | cut -c1-600)
  case "$3" in fertig) notiz "Fertig${m:+ ($m)}" ;; fehler) notiz "Fehler: $m" ;; esac
  [ -n "$1" ] && printf '{"id":"%s","status":"%s","zeit":"%s","meldung":"%s"}\n' "$1" "$3" "$z" "$m" | ablegen "$DATEN/.status/$1.json"
  [ -n "$2" ] && printf '{"status":"%s","zeit":"%s","meldung":"%s"}\n' "$3" "$z" "$m" | ablegen "$DATEN/$2"
  return 0
}
kurz() { printf '%s' "$1" | tail -3 | tr '\n' ' '; }
env_setzen() { sed -i "/^$1=/d" .env; echo "$1=$2" >> .env; chmod 600 .env; }
env_lesen() { sed -n "s/^$1=//p" .env | tail -1; }
profil() { # profil an|aus name — Profil in COMPOSE_PROFILES
  local n="$2" p; p=$(env_lesen COMPOSE_PROFILES | tr ',' ' ')
  p=$(echo " $p " | sed "s/ $n / /g" | xargs)
  [ "$1" = "an" ] && p=$(echo "$p $n" | xargs)
  sed -i '/^COMPOSE_PROFILES=/d' .env
  [ -z "$p" ] || echo "COMPOSE_PROFILES=$(echo "$p" | tr ' ' ',')" >> .env
}
datei_an() { # datei_an an|aus compose.x.yml — Zusatzdatei in COMPOSE_FILE
  local f; f=$(env_lesen COMPOSE_FILE); [ -n "$f" ] || f="docker-compose.yml"
  f=$(echo ":$f:" | sed "s/:$2:/:/g; s/^://; s/:$//")
  [ "$1" = "an" ] && f="$f:$2"
  env_setzen COMPOSE_FILE "$f"
}
holen() { [ -f "$1" ] || curl -fsSL --max-time 30 -o "$1" "$QUELLE/$1?t=$(date +%s)"; }
DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'

# Zertifikat fuer den Mailserver ueber Caddy: einmal per TLS mit SNI = Mailserver bei Caddy anklopfen (on demand,
# die App gibt den Namen frei), dann bis zu 90 Sekunden auf die Datei warten. Braucht einen DNS-Eintrag auf diesen Server.
caddy_zert() { # caddy_zert <name> → 0, wenn das Zertifikat da ist
  local f="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$1/$1.crt" i
  docker compose exec -T caddy test -f "$f" 2>/dev/null && return 0
  notiz "Zertifikat fuer $1 bei Caddy anfordern"
  curl -sk --max-time 20 --resolve "$1:443:127.0.0.1" "https://$1/" -o /dev/null 2>/dev/null || true
  for i in $(seq 1 18); do docker compose exec -T caddy test -f "$f" 2>/dev/null && return 0; sleep 5; done
  return 1
}

bearbeiten() { # bearbeiten <anfrage-datei>
  local f="$1" id aktion tok dom zert viren adr art out
  id=$(feld id 'a-z0-9-' "$f"); aktion=$(feld aktion 'a-z-' "$f"); tok=$(feld token 'A-Za-z0-9+/=_-' "$f")
  dom=$(feld domain 'a-z0-9.-' "$f"); zert=$(feld zert 'a-z' "$f"); viren=$(feld viren 'a-z' "$f"); adr=$(feld adresse 'a-z0-9._+@-' "$f"); art=$(feld art 'a-z' "$f")
  # Ohne Aktion gilt „update“ nur fuer die Datei alter Apps — sonst ist der Auftrag kaputt
  if [ -z "$aktion" ] && [ "$(basename "$f")" != "0-alt.json" ]; then rm -f "$f"; schreib "$id" "" fehler "Auftrag ohne gueltige Aktion"; return 1; fi
  rm -f "$f"
  LOG=""
  if [ -n "$id" ]; then
    log_oeffnen "$DATEN/.status/$id.log" 8 && LOG=/dev/fd/8
    notiz "$(date '+%H:%M:%S') Auftrag ${aktion:-update} gestartet"
  fi
  cd "$DIR" || { schreib "$id" .update-status fehler "Ordner $DIR fehlt"; return 1; }
  case "${aktion:-update}" in
    tunnel-an)
      schreib "$id" .tunnel-status laeuft ""
      [ -n "$tok" ] || { schreib "$id" .tunnel-status fehler "Kein Tunnel-Token in der Anfrage"; return 1; }
      env_setzen RP_TUNNEL_TOKEN "$tok"; profil an tunnel
      if out=$(docker compose up -d cloudflared 2>&1); then schreib "$id" .tunnel-status fertig ""; else schreib "$id" .tunnel-status fehler "$(kurz "$out")"; fi ;;
    tunnel-aus)
      schreib "$id" .tunnel-status laeuft ""
      if out=$(docker compose stop cloudflared 2>&1 && docker compose rm -f cloudflared 2>&1); then profil aus tunnel; sed -i '/^RP_TUNNEL_TOKEN=/d' .env; schreib "$id" .tunnel-status fertig ""
      else schreib "$id" .tunnel-status fehler "$(kurz "$out")"; fi ;;
    webserver-info)
      # Assistent: welcher Webserver ist da, sind Port 80/443 frei, laesst sich einer installieren?
      declare -F ws_info >/dev/null || { schreib "$id" "" fehler "ws_info fehlt im Dienst (install.sh --dienst erneut ausfuehren)"; return 1; }
      if ws_info | ablegen "$DATEN/.webserver-info"; then schreib "$id" "" fertig ""; else schreib "$id" "" fehler "Datenordner nicht beschreibbar"; fi ;;
    webserver)
      # Assistent (nur Port-Modus): Webserver (falls keiner da) + Virtual Host + HTTPS mit install.sh --nur-vhost —
      # dieselben Funktionen wie bei der Installation. Art und Domain hier noch einmal streng pruefen (Whitelist / Regex).
      local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' skript rc letzte
      schreib "$id" "" laeuft ""
      [ -n "$LOG" ] || { schreib "$id" "" fehler "Auftrag ohne id"; return 1; }
      case "$art" in nginx|apache) ;; *) schreib "$id" "" fehler "Unbekannter Webserver (nur nginx oder apache)"; return 1 ;; esac
      if [ -z "$dom" ] || [ ${#dom} -gt 253 ] || ! [[ "$dom" =~ $re ]]; then schreib "$id" "" fehler "Ungueltige Domain"; return 1; fi
      grep -q 'compose.port.yml' .env 2>/dev/null || { schreib "$id" "" fehler "Nur im Port-Modus (ohne eigenen Caddy) moeglich"; return 1; }
      # Kanal 8 (Protokoll) und 9 (Dienst-Sperre) nicht vererben: ein ohne systemd gestarteter Webserver hielte sie sonst fuer immer
      skript=$(mktemp)
      if ! { curl -fsSL --max-time 30 -o "$skript" "$QUELLE/install.sh?t=$(date +%s)" 2>/dev/null && bash -n "$skript" 2>/dev/null && grep -q -- '--nur-vhost' "$skript"; }; then
        if [ -f "$DIR/install.sh" ] && grep -q -- '--nur-vhost' "$DIR/install.sh"; then cp -f "$DIR/install.sh" "$skript"
        else rm -f "$skript"; schreib "$id" "" fehler "install.sh mit --nur-vhost weder von GitHub noch im Ordner gefunden"; return 1; fi
      fi
      RP_DIR="$DIR" RP_KEIN_BANNER=1 RP_QUELLE="$QUELLE" bash "$skript" --nur-vhost --domain "$dom" --webserver "$art" </dev/null >&8 2>&1 8>&- 9>&-; rc=$?
      rm -f "$skript"
      letzte=$(grep -E "$([ "$rc" = 3 ] && echo 'HTTPS|certbot' || echo 'FEHLER|ERROR')" "$LOG" | tail -1 | sed 's/^[^A-Za-z]*//' | tr -d '\000-\010\013-\037' | cut -c1-300)
      ws_info | ablegen "$DATEN/.webserver-info"
      # meldung: „https“ = alles fertig; „http: …“ = Virtual Host steht, Zertifikat noch nicht
      case "$rc" in
        0) schreib "$id" "" fertig "https" ;;
        3) schreib "$id" "" fertig "http: $letzte" ;;
        *) schreib "$id" "" fehler "${letzte:-install.sh --nur-vhost ist fehlgeschlagen (Protokoll)}" ;;
      esac ;;
    mail-an)
      # Eigener Mailserver (compose.mail.yml); Zertifikat von Caddy bzw. certbot, sonst selbst erzeugt (mailkonfig/ssl)
      schreib "$id" "" laeuft ""
      if [ -z "$dom" ] || [ ${#dom} -gt 253 ] || ! [[ "$dom" =~ $DOMAIN_RE ]]; then schreib "$id" "" fehler "Ungueltiger Name des Mailservers"; return 1; fi
      for d in compose.mail.yml compose.mail-caddy.yml compose.mail-le.yml; do holen "$d" || { schreib "$id" "" fehler "$d liess sich nicht laden"; return 1; }; datei_an aus "$d"; done
      env_setzen RP_MAIL_HOST "$dom"; env_setzen RP_MAIL_POSTMASTER "postmaster@${dom#*.}"
      if [ "$viren" = an ]; then env_setzen RP_MAIL_CLAMAV 1; else env_setzen RP_MAIL_CLAMAV 0; fi
      datei_an an compose.mail.yml
      case "$zert" in
        caddy) if caddy_zert "$dom"; then datei_an an compose.mail-caddy.yml; else zert=datei; fi ;;
        le)
          # certbot des Webservers: fehlt das Zertifikat, einmal holen (Webroot nicht noetig: --standalone geht wegen
          # Port 80 nicht, also nginx/apache-Plugin wie bei der Installation)
          if [ ! -f "/etc/letsencrypt/live/$dom/fullchain.pem" ] && command -v certbot >/dev/null 2>&1; then
            local plugin=""; command -v nginx >/dev/null 2>&1 && plugin=nginx; [ -z "$plugin" ] && command -v apache2ctl >/dev/null 2>&1 && plugin=apache
            [ -n "$plugin" ] && certbot certonly "--$plugin" -d "$dom" -n --agree-tos --register-unsafely-without-email >/dev/null 2>&1
          fi
          if [ -f "/etc/letsencrypt/live/$dom/fullchain.pem" ]; then datei_an an compose.mail-le.yml; else zert=datei; fi ;;
        *) zert=datei ;;
      esac
      if [ "$zert" = datei ]; then env_setzen RP_MAIL_SELBSTSIGNIERT 1; else env_setzen RP_MAIL_SELBSTSIGNIERT 0; fi
      # Konfig- und Mail-Ordner gehoeren der App (Nutzer 1000): sie schreibt Konten, Aliase, DKIM und Filter, der
      # Mailserver liest nur (Mails gehoeren dank DMS_VMAIL_UID ebenfalls 1000 — so kann die App sichern).
      if out=$(docker compose pull --ignore-pull-failures mail 2>&1 && docker compose run --rm --no-deps -u root --entrypoint chown app 1000:1000 /mailkonfig /maildaten 2>&1 && docker compose up -d mail app 2>&1); then schreib "$id" "" fertig "$zert"; else schreib "$id" "" fehler "$(kurz "$out")"; fi ;;
    mail-aus)
      schreib "$id" "" laeuft ""
      docker compose stop mail >/dev/null 2>&1; docker compose rm -f mail >/dev/null 2>&1
      for d in compose.mail.yml compose.mail-caddy.yml compose.mail-le.yml; do datei_an aus "$d"; done
      if out=$(docker compose up -d app 2>&1); then schreib "$id" "" fertig ""; else schreib "$id" "" fehler "$(kurz "$out")"; fi ;;
    mail-ordner-weg)
      # gespeicherte Mails eines geloeschten Postfachs — Adresse streng pruefen (kein „..“, kein „/“)
      local lok="${adr%@*}" mdom="${adr#*@}"
      if [[ "$lok" =~ ^[a-z0-9][a-z0-9._+-]*$ ]] && [[ "$mdom" =~ ^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$ ]] && [[ "$lok" != *..* ]] && [[ "$mdom" != *..* ]]; then
        if out=$(docker compose exec -T mail rm -rf -- "/var/mail/$mdom/$lok" 2>&1); then schreib "$id" "" fertig ""; else schreib "$id" "" fehler "$(kurz "$out")"; fi
      else schreib "$id" "" fehler "ungueltige Adresse"; fi ;;
    *)
      schreib "$id" .update-status laeuft ""
      # Erst das neueste update.sh holen: es bringt Dateien, Images und diesen Dienst selbst auf den neuesten Stand
      local neu; neu=$(mktemp)
      if curl -fsSL --max-time 30 -o "$neu" "$QUELLE/update.sh?t=$(date +%s)" 2>/dev/null && bash -n "$neu" 2>/dev/null; then
        [ -n "$id" ] && export RP_STATUS_ID="$id"
        rm -rf "$PRIVAT"
        RP_QUELLE="$QUELLE" exec bash "$neu" --dir "$DIR" --status "$DATEN/.update-status"
      fi
      rm -f "$neu"
      # GitHub nicht erreichbar: nur die Images
      local dienste="app radicale"; grep -q '^COMPOSE_PROFILES=.*tunnel' .env && dienste="$dienste cloudflared"; grep -q 'compose.mail.yml' .env && dienste="$dienste mail"
      if out=$(docker compose pull $dienste 2>&1 && docker compose up -d $dienste 2>&1); then schreib "$id" .update-status fertig ""
      else schreib "$id" .update-status fehler "$(kurz "$out")"; fi ;;
  esac
}

# Alte Apps legen genau eine Datei ab, neue einen Ordner voller Auftraege — beides der Reihe nach abarbeiten.
# Jeder Auftrag wird zuerst in einen Ordner von root verschoben (mv folgt keinem Link) und nur von dort gelesen;
# Links und alles, was keine Datei ist, werden verworfen. .anfragen/ wird nur betreten, wenn es wirklich der
# Ordner im Datenordner ist (nicht ein untergeschobener Link).
PRIVAT=$(mktemp -d) || exit 1
trap 'rm -rf "$PRIVAT"' EXIT
DATEN_P=$(cd -P "$DATEN" 2>/dev/null && pwd) || exit 1
uebernehmen() { # uebernehmen <quelle> <name> — nach $PRIVAT/<name>; 1 = verworfen
  mv -f "$1" "$PRIVAT/$2" 2>/dev/null || return 1
  if [ -L "$PRIVAT/$2" ] || [ ! -f "$PRIVAT/$2" ]; then rm -rf "${PRIVAT:?}/$2"; return 1; fi
}
if [ -e "$DATEN/.update-anfrage" ] || [ -L "$DATEN/.update-anfrage" ]; then uebernehmen "$DATEN/.update-anfrage" 0-alt.json && bearbeiten "$PRIVAT/0-alt.json"; fi
namen=$(cd -P "$DATEN/.anfragen" 2>/dev/null && [ "$(pwd)" = "$DATEN_P/.anfragen" ] && ls -1A 2>/dev/null | grep -E '^[A-Za-z0-9._-]+[.]json$' | sort)
for n in $namen; do
  ( cd -P "$DATEN/.anfragen" 2>/dev/null && [ "$(pwd)" = "$DATEN_P/.anfragen" ] && { [ -e "$n" ] || [ -L "$n" ]; } && uebernehmen "$n" "$n" ) || continue
  bearbeiten "$PRIVAT/$n"
done
[ -n "$(ls -A "$DATEN/.anfragen" 2>/dev/null)" ] && sleep 5
# Status-Dateien aelter als 7 Tage weg
find "$DATEN/.status" -name '*.json' -mtime +7 -delete 2>/dev/null
find "$DATEN/.status" -name '*.log' -mtime +7 -delete 2>/dev/null
exit 0
SKRIPT
  } > /usr/local/bin/redpost-update.neu
# <<< DIENST
  # erst fertig schreiben, dann umbenennen: ein gerade laufender Dienst liest so seine alte Fassung zu Ende
  chmod 755 /usr/local/bin/redpost-update.neu && mv -f /usr/local/bin/redpost-update.neu /usr/local/bin/redpost-update
  local ausloeser=""
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    auftrags_ordner "$daten"
    printf '%s\n' "[Unit]" "Description=RedPost: Auftrag aus dem Panel" "[Path]" "PathExists=$daten/.update-anfrage" "DirectoryNotEmpty=$daten/.anfragen" "[Install]" "WantedBy=multi-user.target" > /etc/systemd/system/redpost-update.path
    # StartLimitIntervalSec=0: viele Auftraege kurz hintereinander duerfen die Ueberwachung nie abschalten
    printf '%s\n' "[Unit]" "Description=RedPost aktualisieren" "StartLimitIntervalSec=0" "ConditionDirectoryNotEmpty=|$daten/.anfragen" "ConditionPathExists=|$daten/.update-anfrage" "[Service]" "Type=oneshot" "ExecStart=/usr/local/bin/redpost-update" > /etc/systemd/system/redpost-update.service
    # Rueckfallebene: jede Minute nachsehen, falls die Pfad-Ueberwachung doch einmal ausfaellt
    printf '%s\n' "[Unit]" "Description=RedPost: Auftraege nachsehen" "[Timer]" "OnBootSec=1min" "OnUnitInactiveSec=1min" "AccuracySec=10s" "[Install]" "WantedBy=timers.target" > /etc/systemd/system/redpost-update.timer
    if systemctl daemon-reload && systemctl enable --now redpost-update.path >/dev/null 2>&1; then ausloeser="systemd"; rm -f /etc/cron.d/redpost-update; systemctl reset-failed redpost-update.path redpost-update.service >/dev/null 2>&1; systemctl restart redpost-update.path >/dev/null 2>&1; systemctl enable --now redpost-update.timer >/dev/null 2>&1; fi
  fi
  # Unraid: kein systemd, /etc und /usr/local liegen im Arbeitsspeicher (nach dem Neustart weg), und cron liest
  # /etc/cron.d als Crontabs je Benutzer (Datei „root“, ohne Benutzerfeld) — eine eigene Datei dort laeuft nie.
  # update_cron baut die root-Crontab aus /boot/config/plugins/dynamix/*.cron (+ Ordner installierter Plugins mit .plg)
  # — bei jedem Start und jeder Zeitplan-Aenderung. Darum: Dienst auf den USB-Stick, Zeitplan nach dynamix/.
  if [ -z "$ausloeser" ] && [ -f /etc/unraid-version ] && [ -d /boot/config ]; then
    mkdir -p /boot/config/plugins/redpost /boot/config/plugins/dynamix
    cp -f /usr/local/bin/redpost-update /boot/config/plugins/redpost/redpost-update
    local zeile="* * * * * bash /boot/config/plugins/redpost/redpost-update >/dev/null 2>&1"
    printf '%s\n' "# RedPost: Auftraege aus dem Panel (angelegt von install.sh)" "$zeile" "" > /boot/config/plugins/dynamix/redpost-update.cron
    rm -f /etc/cron.d/redpost-update /boot/config/plugins/redpost/redpost.cron
    # steht der Eintrag in der Crontab, die Unraid-cron liest? (ohne Pipe: install.sh laeuft mit pipefail)
    rp_cron_drin() { local alle; alle="$(cat /etc/cron.d/root 2>/dev/null || true)"; case "$alle" in *plugins/redpost/redpost-update*) return 0 ;; esac; return 1; }
    # 1. Unraid-Weg
    if [ -x /usr/local/sbin/update_cron ]; then /usr/local/sbin/update_cron >/dev/null 2>&1 || true; fi
    # 2. update_cron fehlt oder liest dynamix/ nicht: direkt in die root-Crontab und cron neu laden lassen
    if ! rp_cron_drin && [ -d /etc/cron.d ]; then
      { cat /etc/cron.d/root 2>/dev/null || true; echo "$zeile"; } > /tmp/redpost-cron.$$ && cat /tmp/redpost-cron.$$ > /etc/cron.d/root
      rm -f /tmp/redpost-cron.$$; crontab /etc/cron.d/root -c /etc/cron.d >/dev/null 2>&1 || true
    fi
    if rp_cron_drin; then ausloeser="cron (Unraid)"
    else
      DIENST_GRUND="$(s "Unraid: der Zeitplan liess sich nicht eintragen" "Unraid: the schedule could not be added") (Unraid $(cat /etc/unraid-version 2>/dev/null | tr -dc '0-9.' | head -c 12), update_cron: $([ -x /usr/local/sbin/update_cron ] && echo ja || echo nein), /etc/cron.d: $(ls /etc/cron.d 2>/dev/null | tr '\n' ' '), crond: $(pgrep -x crond >/dev/null 2>&1 && echo laeuft || echo aus))."
      return 1
    fi
  fi
  # Ohne systemd (z. B. Container-Server, Alpine): cron schaut jede Minute nach einer Anfrage
  if [ -z "$ausloeser" ] && [ -d /etc/cron.d ] && { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; }; then
    printf '%s\n' "# RedPost: Auftrag aus dem Panel (angelegt von install.sh, ohne systemd)" "* * * * * root /usr/local/bin/redpost-update >/dev/null 2>&1" > /etc/cron.d/redpost-update
    chmod 644 /etc/cron.d/redpost-update; ausloeser="cron"
  fi
  [ -n "$ausloeser" ] || { DIENST_GRUND="$(s "Weder systemd noch cron laufen auf diesem Server – ohne einen davon kann der Knopf im Panel nichts ausloesen." "Neither systemd nor cron is running on this server – without one the panel button cannot trigger anything.")"; return 1; }
  auftrags_ordner "$daten"
  printf '%s\naktionen=update tunnel mail anfragen webserver\nstand=5\n' "$PWD" | ablegen "$daten/.updater" \
    || { DIENST_GRUND="$(s "Die Marker-Datei liess sich im Datenordner nicht ablegen." "The marker file could not be written into the data folder.")"; return 1; }
  # gleich einmal fuer den Assistenten festhalten, welcher Webserver da ist (spaeter frisch per Aktion „webserver-info“)
  { ws_info | ablegen "$daten/.webserver-info"; } 2>/dev/null || true
  say "==> Update-Dienst eingerichtet ($ausloeser; Panel → Version unten links → „Jetzt aktualisieren“)" "==> Update service set up ($ausloeser; panel → version at the bottom left → “Update now”)"
}


# 6. Virtual Host fuer die Domain in deinem Webserver (nur im Port-Modus, nur mit Domain).
#    Als Funktion: laeuft auch nach der Einrichtung ueber den Kurzzeit-Link (Schritt 9) mit der dort gewaehlten Domain.
# Webserver selbst einrichten: Kein nginx/Apache auf dem Server (Port-Modus mit Domain) — auf Wunsch einen installieren
#   (Frage: 1 nginx, 2 Apache, 3 keinen; oder --webserver nginx|apache). Danach geht es unten im normalen Weg weiter:
#   Virtual Host anlegen, Konfigtest, Neuladen, Zertifikat per certbot. Ohne Terminal und ohne Schalter: nur die Vorlage.
ws_neu=""
ws_paket() { # ws_paket <paket …> — ueber apt-get bzw. dnf/yum installieren; Ausgabe ins Protokoll, solange ein Spinner
  local log pid n=0 rc=0 txt
  txt="$(s "Installiere" "Installing") $*"
  log=$(mktemp "/tmp/redpost-pakete.XXXXXX") || return 1
  if command -v apt-get >/dev/null 2>&1; then
    ( export DEBIAN_FRONTEND=noninteractive
      apt-get -o DPkg::Lock::Timeout=300 update -qq && apt-get -o DPkg::Lock::Timeout=300 install -y -qq "$@" ) >"$log" 2>&1 &
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@" >"$log" 2>&1 &
  elif command -v yum >/dev/null 2>&1; then yum install -y -q "$@" >"$log" 2>&1 &
  else rm -f "$log"; return 1; fi
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ -t 1 ]; then printf '\r  %s%s%s %s (%s s)' "$R" "${SPIN[$(( n % ${#SPIN[@]} ))]}" "$N" "$txt" "$(( n / 4 ))"
    elif [ "$n" -gt 0 ] && [ $(( n % 40 )) -eq 0 ]; then echo "    $txt … $(( n / 4 )) s"; fi
    n=$((n + 1)); sleep 0.25
  done
  wait "$pid" || rc=$?
  if [ -t 1 ]; then printf '\r\033[K'; fi
  if [ "$rc" = 0 ]; then say "    Installiert: $*" "    Installed: $*"
  else say "    FEHLER: $* liess sich nicht installieren (Ausgabe unten)." "    ERROR: $* could not be installed (output below)."; tail -n 12 "$log" | sed 's/^/      /'; fi
  rm -f "$log"
  return "$rc"
}
ws_starten() { # ws_starten nginx|apache2|httpd — einschalten (startet mit dem Server) und starten; ohne systemd direkt
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl enable "$1" >/dev/null 2>&1 || true
    systemctl restart "$1" >/dev/null 2>&1 || return 1
  else
    case "$1" in
      nginx) nginx -s reload >/dev/null 2>&1 || nginx || return 1 ;;
      apache2) apache2ctl start >/dev/null 2>&1 || return 1 ;;
      # RHEL & Co.: das Platzhalter-Zertifikat von mod_ssl legt sonst httpd-init.service (systemd) an
      httpd) if [ ! -s /etc/pki/tls/certs/localhost.crt ] && [ -x /usr/libexec/httpd-ssl-gencerts ]; then /usr/libexec/httpd-ssl-gencerts >/dev/null 2>&1 || true; fi
        httpd -k start >/dev/null 2>&1 || return 1 ;;
    esac
  fi
}
ws_anbieten() { # fragen (oder --webserver), installieren, starten — setzt webserver und ws_neu; Rueckgabe 1 = Vorlage
  local wahl="$WS_WAHL" dienst wer=""
  local -a pakete
  case "$wahl" in keiner|none) return 1 ;; esac
  if ! command -v apt-get >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
    [ -z "$wahl" ] || say "    $wahl laesst sich hier nicht installieren (weder apt-get noch dnf/yum gefunden)." "    $wahl cannot be installed here (neither apt-get nor dnf/yum found)."
    return 1
  fi
  # Port 80/443 belegt (anderer Proxy, Container …): ein zusaetzlicher Webserver kaeme nicht an die Ports
  if belegt 80 || belegt 443; then
    wer=$(wer_lauscht 80 || true); [ -n "$wer" ] || wer=$(wer_lauscht 443 || true)
    say "==> Kein nginx/Apache gefunden, aber Port 80/443 ist belegt (${wer:-unbekannter Dienst}) — einen Webserver installiere ich daneben nicht." "==> No nginx/Apache found, but port 80/443 is in use (${wer:-unknown service}) — I will not install a web server next to it."
    return 1
  fi
  if [ -z "$wahl" ]; then
    [ -t 0 ] || return 1   # ohne Terminal (curl | bash ohne Bildschirm) und ohne --webserver: Vorlage wie bisher
    echo ""
    say "==> Auf diesem Server laeuft weder nginx noch Apache." "==> Neither nginx nor Apache is installed on this server."
    say "    Ich kann einen installieren, den Virtual Host fuer $DOMAIN anlegen und HTTPS per certbot holen." "    I can install one, create the virtual host for $DOMAIN and get HTTPS via certbot."
    echo "  ${Y}${Z_FRAGE}${N} ${B}$(s "Webserver installieren:" "Install a web server:")${N}   ${C}1${N}) nginx ($(s empfohlen recommended))   ${C}2${N}) Apache   ${C}3${N}) $(s "Keinen (nur Vorlage anzeigen)" "None (only show the template)")"
    read -r -p "    [1] " wahl </dev/tty || true
    case "${wahl:-1}" in 1|nginx) wahl="nginx" ;; 2|apache|apache2|httpd) wahl="apache" ;; *) return 1 ;; esac
  fi
  if [ "$wahl" = "nginx" ]; then dienst="nginx"; pakete=(nginx)
  elif command -v apt-get >/dev/null 2>&1; then dienst="apache2"; pakete=(apache2)
  else dienst="httpd"; pakete=(httpd mod_ssl); fi
  say "==> $dienst wird installiert …" "==> Installing $dienst …"
  if [ "${RP_DRY_RUN:-}" = "1" ]; then tu ws_paket "${pakete[@]}"; webserver="$dienst"; ws_neu="ja"; return 0; fi
  ws_paket "${pakete[@]}" || return 1
  if [ "$dienst" = "apache2" ]; then a2enmod -q proxy proxy_http headers rewrite >/dev/null 2>&1 || true; fi
  # RHEL & Co.: SELinux verbietet dem Webserver sonst die Verbindung zur App auf 127.0.0.1 (502)
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then setsebool -P httpd_can_network_connect 1 >/dev/null 2>&1 || true; fi
  if ! ws_starten "$dienst"; then
    say "    FEHLER: $dienst ist installiert, startet aber nicht (systemctl status $dienst)." "    ERROR: $dienst is installed but does not start (systemctl status $dienst)."
    return 1
  fi
  # Firewall: nur 80/443 fuer den Webserver oeffnen — der Port der App bleibt zu (sie hoert nur auf 127.0.0.1)
  if command -v ufw >/dev/null 2>&1; then
    case "$(ufw status 2>/dev/null || true)" in *"Status: active"*)
      ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true
      say "    Firewall (ufw): Port 80 und 443 freigegeben." "    Firewall (ufw): ports 80 and 443 opened." ;;
    esac
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    { firewall-cmd -q --permanent --add-service=http --add-service=https && firewall-cmd -q --reload; } >/dev/null 2>&1 || true
    say "    Firewall (firewalld): http und https freigegeben." "    Firewall (firewalld): http and https opened."
  fi
  webserver="$dienst"; ws_neu="ja"
  say "==> $dienst laeuft und startet kuenftig mit dem Server." "==> $dienst is running and will start with the server."
}
certbot_installieren() { # certbot_installieren nginx|apache — certbot + Plugin aus der Paketverwaltung (RHEL & Co.: aus EPEL)
  if ! command -v apt-get >/dev/null 2>&1 && [ -f /etc/redhat-release ] && ! grep -qi fedora /etc/redhat-release && ! rpm -q epel-release >/dev/null 2>&1; then
    tu ws_paket epel-release || true
  fi
  tu ws_paket certbot "python3-certbot-$1"
}
hsts_sichern() { # der HTTPS-Eintrag (von certbot ergaenzt bzw. angelegt) muss HSTS senden — fehlt die Zeile, nachtragen
  local f="" z="" muster="" ok=""
  [ "${RP_DRY_RUN:-}" != "1" ] || return 0
  case "$vhost_angelegt" in
    nginx) f="$datei"; muster='listen[ \t]+[^;]*443'; z='    add_header Strict-Transport-Security "max-age=31536000" always;' ;;
    apache2|httpd) f="${datei%.conf}-le-ssl.conf"; muster='<VirtualHost[^>]*:443>'; z='    Header always set Strict-Transport-Security "max-age=31536000"' ;;
    *) return 0 ;;
  esac
  [ -f "$f" ] || return 0
  if grep -q 'Strict-Transport-Security' "$f"; then say "    HSTS aktiv (Strict-Transport-Security, 1 Jahr)." "    HSTS active (Strict-Transport-Security, 1 year)."; return 0; fi
  grep -qE "$muster" "$f" || return 0
  cp -a "$f" "$f.bak-hsts"
  awk -v z="$z" -v m="$muster" '{ print } !d && $0 ~ m { print z; d = 1 }' "$f.bak-hsts" > "$f.neu" && cat "$f.neu" > "$f"
  rm -f "$f.neu"
  case "$vhost_angelegt" in
    nginx) if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || systemctl start nginx 2>/dev/null || nginx || pkill -HUP -o -x nginx; ok=1; fi ;;
    apache2) if apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 2>/dev/null || apache2ctl graceful; ok=1; fi ;;
    httpd) if httpd -t >/dev/null 2>&1; then systemctl reload httpd 2>/dev/null || httpd -k graceful; ok=1; fi ;;
  esac
  if [ -n "$ok" ]; then rm -f "$f.bak-hsts"; say "    HSTS ergaenzt (Strict-Transport-Security, 1 Jahr): $f" "    HSTS added (Strict-Transport-Security, 1 year): $f"
  else cat "$f.bak-hsts" > "$f"; rm -f "$f.bak-hsts"; say "    FEHLER: HSTS liess sich nicht ergaenzen (Konfigtest) — bitte von Hand in $f:  $z" "    ERROR: could not add HSTS (config test) — please add by hand in $f:  $z"; fi
}
vhost_angelegt=""; fremd=""
vhost_einrichten() {
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ] && [ "$VHOST" = "ja" ]; then
  webserver=""
  if command -v nginx >/dev/null 2>&1; then webserver="nginx"
  elif command -v apache2ctl >/dev/null 2>&1; then webserver="apache2"
  elif command -v httpd >/dev/null 2>&1; then webserver="httpd"
  fi
  # Gibt es fuer die Domain schon einen fremden Eintrag (z. B. das alte Zipline)? Dann nichts anfassen — umstellen
  # ist ein bewusster Schritt (siehe Umzug unten), sonst stritten sich zwei Eintraege um die Domain.
  fremd=$(grep -RlsE "^[[:space:]]*(server_name|ServerName|ServerAlias)[[:space:]]+(.*[[:space:]])?${DOMAIN//./\\.}([[:space:];]|$)" /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null | grep -v 'redpost' | head -1 || true)
  # Zeigt der Eintrag schon auf RedPost (z. B. nach dem Umzug von Zipline)? Dann ist alles erledigt.
  if [ -n "$fremd" ] && grep -qE "(proxy_pass|ProxyPass[[:space:]]+/)[[:space:]]+http://(127\.0\.0\.1|localhost):${PORT}(/|;|[[:space:]]|$)" "$fremd"; then
    say "==> $DOMAIN zeigt schon auf RedPost ($fremd)." "==> $DOMAIN already points to RedPost ($fremd)."
    fremd=""; webserver=""; vhost_angelegt="vorhanden"; https_ok=1
  fi
  if [ -n "$fremd" ]; then
    say "==> Fuer $DOMAIN gibt es schon einen Eintrag: $fremd — den fasse ich nicht an." "==> There is already an entry for $DOMAIN: $fremd — I will not touch it."
    webserver=""
  fi
  # Kein nginx/Apache da: auf Wunsch einen installieren (setzt webserver) — danach weiter wie mit vorhandenem Webserver
  if [ -z "$webserver" ] && [ -z "$fremd" ] && [ "$vhost_angelegt" != "vorhanden" ]; then ws_anbieten || true; fi
  if [ -n "$webserver" ] && { [ -n "$ws_neu" ] || ja "==> $(s "Virtual Host fuer $DOMAIN in $webserver anlegen (Backup vorhandener Dateien, Konfigtest, Neuladen)?" "Create a virtual host for $DOMAIN in $webserver (backup of existing files, config test, reload)?")" "j"; }; then
    stempel=$(date +%Y%m%d-%H%M%S)
    if [ "$webserver" = "nginx" ]; then
      if [ -d /etc/nginx/sites-enabled ]; then datei=/etc/nginx/sites-available/redpost.conf; link=/etc/nginx/sites-enabled/redpost.conf
      else datei=/etc/nginx/conf.d/redpost.conf; link=""; fi
      inhalt="# RedPost — angelegt von install.sh am $stempel
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    add_header Strict-Transport-Security \"max-age=31536000\" always;
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_read_timeout 3600s;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}"
      [ -f "$datei" ] && tu cp -a "$datei" "$datei.bak-$stempel"
      if [ "${RP_DRY_RUN:-}" = "1" ]; then echo "    ($(s Probelauf "dry run")) $datei:"; echo "$inhalt" | sed 's/^/        /'; else printf '%s\n' "$inhalt" > "$datei"; fi
      [ -n "$link" ] && tu ln -sf "$datei" "$link"
      if tu nginx -t; then tu systemctl reload nginx 2>/dev/null || tu nginx -s reload 2>/dev/null || tu systemctl start nginx 2>/dev/null || tu nginx || tu pkill -HUP -o -x nginx; vhost_angelegt="$webserver"
      else say "    FEHLER: nginx -t schlaegt fehl — Datei $datei bitte pruefen (Backup: $datei.bak-$stempel)." "    ERROR: nginx -t fails — please check $datei (backup: $datei.bak-$stempel)."; fi
    else
      if [ "$webserver" = "apache2" ]; then datei=/etc/apache2/sites-available/redpost.conf; else datei=/etc/httpd/conf.d/redpost.conf; fi
      inhalt="# RedPost — angelegt von install.sh am $stempel
<VirtualHost *:80>
    ServerName $DOMAIN
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:$PORT/
    ProxyPassReverse / http://127.0.0.1:$PORT/
    RequestHeader set X-Forwarded-Proto \"expr=%{REQUEST_SCHEME}\"
    Header always set Strict-Transport-Security \"max-age=31536000\"
</VirtualHost>"
      [ -f "$datei" ] && tu cp -a "$datei" "$datei.bak-$stempel"
      if [ "${RP_DRY_RUN:-}" = "1" ]; then echo "    ($(s Probelauf "dry run")) $datei:"; echo "$inhalt" | sed 's/^/        /'; else printf '%s\n' "$inhalt" > "$datei"; fi
      if [ "$webserver" = "apache2" ]; then
        tu a2enmod -q proxy proxy_http headers
        tu a2ensite -q redpost.conf
        if tu apache2ctl configtest; then tu systemctl reload apache2 2>/dev/null || tu apache2ctl graceful; vhost_angelegt="$webserver"; else say "    FEHLER: Apache-Konfigtest schlaegt fehl — $datei bitte pruefen." "    ERROR: Apache config test fails — please check $datei."; fi
      else
        if tu httpd -t; then tu systemctl reload httpd 2>/dev/null || tu httpd -k graceful; vhost_angelegt="$webserver"; else say "    FEHLER: httpd -t schlaegt fehl — $datei bitte pruefen." "    ERROR: httpd -t fails — please check $datei."; fi
      fi
    fi
  elif [ -z "$webserver" ] && [ -z "$fremd" ] && [ "$vhost_angelegt" != "vorhanden" ]; then
    say "==> Keinen nginx/Apache gefunden — die Vorlage fuer deinen Webserver steht unten." "==> No nginx/Apache found — the template for your web server is shown below."
    if ! belegt 80 && ! belegt 443; then say "    Oder alles automatisch (Webserver, Virtual Host, HTTPS):  sudo bash install.sh --webserver nginx  (bzw. apache)" "    Or everything automatically (web server, virtual host, HTTPS):  sudo bash install.sh --webserver nginx  (or apache)"; fi
  fi

  # 7. Zertifikat per certbot (HTTP-01 ueber den gerade angelegten Virtual Host)
  if [ -n "$vhost_angelegt" ] && [ "$vhost_angelegt" != "vorhanden" ]; then
    plugin="nginx"; [ "$vhost_angelegt" = "nginx" ] || plugin="apache"
    meine_ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    domain_ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
    if [ -n "$meine_ip" ] && [ "$domain_ip" != "$meine_ip" ]; then
      # selbst installierter Webserver: certbot schon mitbringen — spaeter reicht dann der eine Befehl unten
      if [ -n "$ws_neu" ] && ! command -v certbot >/dev/null 2>&1; then certbot_installieren "$plugin" || true; fi
      say "==> $DOMAIN zeigt auf '${domain_ip:-nichts}', dieser Server hat $meine_ip — Zertifikat spaeter holen:" "==> $DOMAIN points to '${domain_ip:-nothing}', this server has $meine_ip — get the certificate later:"
      echo "    certbot --$plugin -d $DOMAIN --redirect"
    elif ja "==> $(s "HTTPS-Zertifikat fuer $DOMAIN mit certbot holen (Let's Encrypt)?" "Get an HTTPS certificate for $DOMAIN with certbot (Let's Encrypt)?")" "j"; then
      if ! command -v certbot >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then certbot_installieren "$plugin" || true
        else say "    certbot fehlt und konnte nicht installiert werden — bitte von Hand: certbot --$plugin -d $DOMAIN --redirect" "    certbot is missing and could not be installed — please run by hand: certbot --$plugin -d $DOMAIN --redirect"; fi
      fi
      if command -v certbot >/dev/null 2>&1 || [ "${RP_DRY_RUN:-}" = "1" ]; then
        [ -n "$EMAIL" ] || EMAIL=$(frage "    $(s "E-Mail fuer Ablauf-Hinweise von Let's Encrypt (leer = keine)" "Email for Let's Encrypt expiry notices (empty = none)")" "")
        if [ -n "$EMAIL" ]; then mail_arg=(-m "$EMAIL"); else mail_arg=(--register-unsafely-without-email); fi
        if tu certbot "--$plugin" -d "$DOMAIN" --redirect -n --agree-tos "${mail_arg[@]}"; then https_ok=1; hsts_sichern || true
        else say "    certbot hat nicht geklappt (Ausgabe oben). Spaeter nochmal: certbot --$plugin -d $DOMAIN --redirect" "    certbot did not work (output above). Try again later: certbot --$plugin -d $DOMAIN --redirect"; fi
      fi
    fi
  fi
fi
}
# ws_info — JSON fuer den Einrichtungs-Assistenten: vorhandener Webserver, Port 80/443, Paketverwaltung, certbot, Weg
#   nach aussen. Steht auch woertlich im Update-Dienst (declare -f, Aktion „webserver-info“) — nur EINE Fassung.
ws_info() {
  local ws="" frei=true wer="" paket=false cb=false modus=caddy p
  if command -v nginx >/dev/null 2>&1; then ws="nginx"
  elif command -v apache2ctl >/dev/null 2>&1; then ws="apache2"
  elif command -v httpd >/dev/null 2>&1; then ws="httpd"; fi
  for p in 80 443; do
    if command -v ss >/dev/null 2>&1; then
      ss -ltnH "sport = :$p" 2>/dev/null | grep -q . || continue
      [ -n "$wer" ] || wer=$(ss -ltnpH "sport = :$p" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | sed 's/users:(("//' || true)
    else
      (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || continue
    fi
    frei=false
  done
  if command -v apt-get >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then paket=true; fi
  if command -v certbot >/dev/null 2>&1; then cb=true; fi
  if grep -q 'compose.port.yml' .env 2>/dev/null; then modus=port; fi
  wer=$(printf '%s' "$wer" | tr -cd 'A-Za-z0-9._-' | cut -c1-40)
  printf '{"zeit":"%s","modus":"%s","webserver":"%s","portsFrei":%s,"belegtVon":"%s","paketverwaltung":%s,"certbot":%s}\n' "$(date -Is)" "$modus" "$ws" "$frei" "$wer" "$paket" "$cb"
}

# Nur den Update-Dienst neu einrichten (update.sh ruft das nach jedem Update auf) — ohne Fragen, sonst bleibt alles
if [ -n "$NUR_DIENST" ]; then
  updater_einrichten || { say "FEHLER: Update-Dienst nicht eingerichtet: $DIENST_GRUND" "ERROR: update service not set up: $DIENST_GRUND"; exit 1; }
  exit 0
fi

# Nur Webserver + Virtual Host + HTTPS (Update-Dienst, Aktion „webserver“ aus dem Einrichtungs-Assistenten) — ohne Fragen,
# mit denselben Funktionen wie die Installation. Rueckgabe: 0 = mit HTTPS, 3 = Virtual Host steht, HTTPS noch nicht, 1 = Fehler.
if [ -n "$NUR_VHOST" ]; then
  # Sperre als PID-Datei (kein flock: ein ohne systemd gestarteter Webserver erbte den Kanal und hielte sie fuer immer)
  v_sperre="$PWD/.webserver.lock"
  if [ -f "$v_sperre" ] && v_pid=$(tr -cd '0-9' < "$v_sperre") && [ -n "$v_pid" ] && kill -0 "$v_pid" 2>/dev/null; then
    say "FEHLER: Es laeuft schon eine Einrichtung des Webservers." "ERROR: A web server setup is already running."; exit 1
  fi
  echo "$$" > "$v_sperre"; trap 'rm -f "$v_sperre"' EXIT
  grep -q 'compose.port.yml' .env 2>/dev/null || { say "FEHLER: Diese Installation hat einen eigenen Caddy (kein Port-Modus) — dort holt Caddy das Zertifikat selbst." "ERROR: This installation has its own Caddy (not port mode) — Caddy gets the certificate itself."; exit 1; }
  PORT=$(sed -n 's/^RP_PORT=//p' .env | tail -1 | tr -d '[:space:]')
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { say "FEHLER: RP_PORT fehlt in der .env." "ERROR: RP_PORT is missing in .env."; exit 1; }
  [ -n "$DOMAIN" ] || DOMAIN=$(sed -n 's/^RP_PROXY_DOMAIN=//p' .env | tail -1 | tr -d '[:space:]')
  v_re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  { [ "${#DOMAIN}" -le 253 ] && [[ "$DOMAIN" =~ $v_re ]]; } || { say "FEHLER: ungueltige Domain: $DOMAIN" "ERROR: invalid domain: $DOMAIN"; exit 1; }
  case "$WS_WAHL" in ""|nginx|apache|apache2|httpd) ;; *) say "FEHLER: --webserver: nginx oder apache" "ERROR: --webserver: nginx or apache"; exit 1 ;; esac
  MODUS="port"; VHOST="ja"; https_ok=""
  if grep -q '^RP_PROXY_DOMAIN=' .env; then sed -i "s|^RP_PROXY_DOMAIN=.*|RP_PROXY_DOMAIN=$DOMAIN|" .env; else echo "RP_PROXY_DOMAIN=$DOMAIN" >> .env; fi
  say "==> Webserver fuer $DOMAIN einrichten (RedPost auf 127.0.0.1:$PORT)" "==> Setting up the web server for $DOMAIN (RedPost on 127.0.0.1:$PORT)"
  vhost_einrichten
  if [ -z "$vhost_angelegt" ]; then
    if [ -n "$fremd" ]; then say "FEHLER: Fuer $DOMAIN gibt es schon einen anderen Eintrag ($fremd) — den fasse ich nicht an. Bitte dort auf 127.0.0.1:$PORT weiterleiten." "ERROR: There is already another entry for $DOMAIN ($fremd) — I will not touch it. Please forward it to 127.0.0.1:$PORT there."
    elif [ -z "${webserver:-}" ]; then say "FEHLER: Kein Webserver eingerichtet (siehe oben) — Weiterleitung bitte von Hand auf 127.0.0.1:$PORT." "ERROR: No web server set up (see above) — please forward to 127.0.0.1:$PORT by hand."
    else say "FEHLER: Der Virtual Host liess sich nicht anlegen (siehe oben)." "ERROR: The virtual host could not be created (see above)."; fi
    exit 1
  fi
  if [ -n "${https_ok:-}" ]; then say "==> Fertig. RedPost laeuft unter  https://$DOMAIN" "==> Done. RedPost runs at  https://$DOMAIN"; exit 0; fi
  say "==> Virtual Host steht (http://$DOMAIN) — HTTPS noch nicht: sobald die Domain auf diesen Server zeigt, nochmal versuchen." "==> Virtual host is in place (http://$DOMAIN) — no HTTPS yet: try again once the domain points to this server."
  exit 3
fi

say "==> RedPost wird eingerichtet" "==> Setting up RedPost"

# 1. Docker (falls noch nicht da)
if ! command -v docker >/dev/null 2>&1; then
  say "==> Docker wird installiert …" "==> Installing Docker …"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || { say "FEHLER: 'docker compose' fehlt. Bitte Docker aktualisieren." "ERROR: 'docker compose' is missing. Please update Docker."; exit 1; }
for f in docker-compose.yml compose.caddy.yml compose.port.yml Caddyfile; do
  [ -f "$f" ] || curl -fsSL -o "$f" "$QUELLE/$f" || { say "FEHLER: $f fehlt neben install.sh und konnte nicht geladen werden." "ERROR: $f is missing next to install.sh and could not be downloaded."; exit 1; }
done

# 2. Bei wenig Arbeitsspeicher eine Auslagerungsdatei anlegen (unter 1,5 GB RAM, noch kein Swap)
ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$ram_mb" -lt 1500 ] && [ "$(swapon --noheadings 2>/dev/null | wc -l)" -eq 0 ] && [ ! -f /swapfile ]; then
  say "==> Nur ${ram_mb} MB RAM: lege 1 GB Auslagerungsdatei an …" "==> Only ${ram_mb} MB RAM: creating a 1 GB swap file …"
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 3. .env: Datenbank-Passwort nur beim ersten Mal (sonst passt es nicht mehr zur Datenbank)
# 3a. .env fehlt, aber die Container dieser Installation gibt es noch (z. B. Unraid nach einem Neustart: Ordner im RAM weg,
#     Docker-Volumes noch da): Datenbank-Passwort von dort — ein neu gewuerfeltes passte nicht mehr zur Datenbank.
#     Eine NEU angelegte .env wird bei einem Abbruch (Strg+C) vor Schritt 4 wieder entfernt — sonst fehlte spaeter der Weg nach aussen.
ENV_NEU=0; WEG_FERTIG=0
if [ ! -f .env ]; then
  env_db=$(docker ps -aq --filter "label=com.docker.compose.project=$(basename "$PWD")" --filter label=com.docker.compose.service=db 2>/dev/null || true)
  env_db=${env_db%%$'\n'*}
  env_pw=""
  [ -n "$env_db" ] && env_pw=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$env_db" 2>/dev/null | sed -n 's/^POSTGRES_PASSWORD=//p' || true)
  if [ -n "$env_pw" ]; then
    printf 'DB_PASSWORD=%s\nTZ=Europe/Berlin\n' "$env_pw" > .env && chmod 600 .env
    say "==> .env fehlte — Datenbank-Passwort aus dem vorhandenen Datenbank-Container übernommen" "==> .env was missing — database password taken from the existing database container"
  else
    ENV_NEU=1
  fi
fi
trap 'if [ "${ENV_NEU:-0}" = 1 ] && [ "${WEG_FERTIG:-0}" != 1 ]; then rm -f "$PWD/.env"; fi' EXIT
if [ ! -f .env ]; then
  printf 'DB_PASSWORD=%s\nTZ=Europe/Berlin\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > .env
  chmod 600 .env
  say "==> .env mit zufaelligem Datenbank-Passwort angelegt" "==> Created .env with a random database password"
fi
# Sprache merken — gilt auch fuer den Einrichtungs-Assistenten
if grep -q '^RP_LANG=' .env; then sed -i "s/^RP_LANG=.*/RP_LANG=$SPR/" .env; else echo "RP_LANG=$SPR" >> .env; fi

# Weg nach aussen sichern: kennt die .env keinen (z. B. nach einer abgebrochenen Einrichtung), wuerde ein Neustart den
# freigegebenen Port bzw. Caddy verlieren — dann vom laufenden Container uebernehmen, sonst aus der letzten Sicherung.
weg_retten() {
  WEG_GERETTET=""
  if grep -q '^COMPOSE_FILE=' .env 2>/dev/null; then return 0; fi
  local proj c port ip alt
  proj=$(basename "$PWD")
  c=$(docker ps -q --filter "label=com.docker.compose.project=$proj" --filter label=com.docker.compose.service=caddy 2>/dev/null || true)
  if [ -n "$c" ]; then
    echo "COMPOSE_FILE=docker-compose.yml:compose.caddy.yml" >> .env; WEG_GERETTET="Caddy"; return 0
  fi
  c=$(docker ps -q --filter "label=com.docker.compose.project=$proj" --filter label=com.docker.compose.service=app 2>/dev/null || true)
  c=${c%%$'\n'*}
  port=""; ip=""
  if [ -n "$c" ]; then
    port=$(docker inspect -f '{{with index .HostConfig.PortBindings "3000/tcp"}}{{(index . 0).HostPort}}{{end}}' "$c" 2>/dev/null || true)
    ip=$(docker inspect -f '{{with index .HostConfig.PortBindings "3000/tcp"}}{{(index . 0).HostIp}}{{end}}' "$c" 2>/dev/null || true)
  fi
  if [ -n "$port" ]; then
    # leere HostIp heisst: auf allen Adressen (so war es bisher erreichbar)
    printf 'COMPOSE_FILE=docker-compose.yml:compose.port.yml\nRD_PORT=%s\nRD_BIND=%s\n' "$port" "${ip:-0.0.0.0}" >> .env
    WEG_GERETTET="Port ${ip:-0.0.0.0}:$port"; return 0
  fi
  for alt in $(ls -1d .sicherung/*/ 2>/dev/null | sort -r); do
    if grep -q '^COMPOSE_FILE=' "${alt}.env" 2>/dev/null; then
      grep -E '^(COMPOSE_FILE|RP_PORT|RP_BIND|RP_PROXY_DOMAIN)=' "${alt}.env" >> .env || true
      WEG_GERETTET="Sicherung ${alt%/}"; return 0
    fi
  done
  return 0
}
weg_retten
[ -n "$WEG_GERETTET" ] && say "==> Die .env kannte keinen Weg nach außen — vom laufenden RedPost übernommen ($WEG_GERETTET)" "==> .env had no way in — taken over from the running RedPost ($WEG_GERETTET)"

# 4. Weg nach aussen festlegen — nur, solange die .env noch keinen kennt
if ! grep -q '^COMPOSE_FILE=' .env; then
  # Bestehende Installation mit altem Compose (Caddy stand noch in docker-compose.yml): Caddy behalten.
  if [ -z "$MODUS" ] && docker ps --filter "label=com.docker.compose.service=caddy" --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | grep -qx "$PWD"; then
    MODUS="caddy"
  fi
  if [ -z "$MODUS" ]; then
    if belegt 80 || belegt 443; then
      server=$(wer_lauscht 80 || true); [ -n "$server" ] || server=$(wer_lauscht 443 || true)
      echo ""
      say "==> Port 80/443 sind schon belegt (${server:-unbekannter Dienst})." "==> Port 80/443 are already in use (${server:-unknown service})."
      say "    RedPost bekommt dann einen eigenen Port auf 127.0.0.1, und dein Webserver" "    RedPost then gets its own port on 127.0.0.1, and your web server"
      say "    leitet die Domain dorthin weiter (Virtual Host, HTTPS ueber deinen Webserver)." "    forwards the domain to it (virtual host, HTTPS via your web server)."
      if ja "    $(s "So einrichten? Bei Nein versucht Caddy, Port 80/443 selbst zu belegen." "Set it up this way? If not, Caddy tries to take port 80/443 itself.")" "j"; then MODUS="port"; else MODUS="caddy"; fi
    else
      MODUS="caddy"
    fi
  fi

  if [ "$MODUS" = "port" ]; then
    if [ -z "$PORT" ]; then
      for p in 8080 8081 8082 8088 8090 8100 8180 8280 3100 3200 9080; do belegt "$p" || { PORT=$p; break; }; done
      [ -n "$PORT" ] || { say "FEHLER: kein freier Port gefunden. Bitte mit --port angeben." "ERROR: no free port found. Please pass one with --port."; exit 1; }
      PORT=$(frage "    $(s "Port fuer RedPost (frei)" "Port for RedPost (free)")" "$PORT")
    fi
    belegt "$PORT" && { say "FEHLER: Port $PORT ist belegt." "ERROR: port $PORT is in use."; exit 1; }
    [ -n "$DOMAIN" ] || DOMAIN=$(frage "    $(s "Domain, unter der das Panel laufen soll (leer = spaeter)" "Domain for the panel (empty = later)")" "")
    DOMAIN="${DOMAIN,,}"
    {
      echo "COMPOSE_FILE=docker-compose.yml:compose.port.yml"
      echo "RP_PORT=$PORT"
      echo "RP_BIND=127.0.0.1"
      echo "RP_PROXY_DOMAIN=$DOMAIN"
    } >> .env
    say "==> App hoert auf 127.0.0.1:$PORT (ohne eigenen Caddy)" "==> App listens on 127.0.0.1:$PORT (without its own Caddy)"
  else
    echo "COMPOSE_FILE=docker-compose.yml:compose.caddy.yml" >> .env
    say "==> Caddy uebernimmt Port 80/443 und holt das Zertifikat selbst" "==> Caddy takes port 80/443 and gets the certificate by itself"
  fi
fi
WEG_FERTIG=1

# Werte aus der .env (auch bei einem zweiten Aufruf)
PORT=$(sed -n 's/^RP_PORT=//p' .env | tail -1)
[ -n "$DOMAIN" ] || DOMAIN=$(sed -n 's/^RP_PROXY_DOMAIN=//p' .env | tail -1)
grep -q 'compose.port.yml' .env && MODUS="port" || MODUS="caddy"
# --domain beim zweiten Aufruf: in der .env nachtragen, damit der Assistent sie vorwaehlt
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ]; then
  [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || { say "FEHLER: ungueltige Domain: $DOMAIN" "ERROR: invalid domain: $DOMAIN"; exit 1; }
  if grep -q '^RP_PROXY_DOMAIN=' .env; then sed -i "s|^RP_PROXY_DOMAIN=.*|RP_PROXY_DOMAIN=$DOMAIN|" .env; else echo "RP_PROXY_DOMAIN=$DOMAIN" >> .env; fi
fi

# Passt das Datenbank-Passwort der .env nicht mehr zur Datenbank (.env neu angelegt, das Daten-Volume ist aber das
# alte — etwa nach einem Unraid-Neustart oder einer zweiten Installation), kommt die App nie an ihre Daten (502).
# Im Datenbank-Container geht der lokale Socket ohne Passwort: darueber das Passwort der .env setzen, Daten bleiben.
# Geprueft wird ueber die Netz-Adresse des Containers (wie die App) — 127.0.0.1 ist dort ohne Passwort erlaubt.
# Rueckgabe: 0 = passt, 2 = angeglichen (App neu gestartet), 1 = liess sich nicht angleichen
db_passwort_angleichen() {
  local i
  [ -n "$(docker compose ps -q db 2>/dev/null)" ] || return 0
  for i in $(seq 1 30); do docker compose exec -T db pg_isready -q >/dev/null 2>&1 && break; sleep 1; done
  docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$(hostname -i 2>/dev/null | cut -d" " -f1)" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select 1"' >/dev/null 2>&1 && return 0
  printf '%s\n' "ALTER USER CURRENT_USER PASSWORD :'pw';" | docker compose exec -T db sh -c 'psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -v pw="$POSTGRES_PASSWORD"' >/dev/null 2>&1 || return 1
  docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$(hostname -i 2>/dev/null | cut -d" " -f1)" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select 1"' >/dev/null 2>&1 || return 1
  docker compose restart app >/dev/null 2>&1 || true
  return 2
}

# 5. Starten
if [ -d .output ]; then docker compose up -d --build; else docker compose pull && docker compose up -d; fi
db_rc=0; db_passwort_angleichen || db_rc=$?
if [ "$db_rc" = 2 ]; then say "    Das Datenbank-Passwort passte nicht zur .env — angeglichen (Daten bleiben)." "    The database password did not match .env — fixed (data kept)."
elif [ "$db_rc" = 1 ]; then say "    FEHLER: Das Datenbank-Passwort passt nicht zur .env und liess sich nicht angleichen." "    ERROR: The database password does not match .env and could not be fixed."; fi

# 5b. Update-Dienst einrichten (Funktion steht oben)
updater_einrichten || say "    Update-Dienst nicht eingerichtet: $DIENST_GRUND" "    Update service not set up: $DIENST_GRUND"

# 6. + 7. Virtual Host und Zertifikat (Funktionen oben, auch fuer --nur-vhost)
vhost_einrichten

# 8. Auf die App warten und den Setup-Code zeigen
say "==> Warte auf den Start …" "==> Waiting for the start …"
for n in $(seq 1 60); do
  if docker compose logs app 2>/dev/null | grep -q 'Setup-Code\|bereit\|ready'; then break; fi
  for k in 0 1 2 3 4 5 6 7; do [ -t 1 ] && printf '\r  %s%s%s %s' "$R" "${SPIN[$(( (n * 8 + k) % ${#SPIN[@]} ))]}" "$N" "$(s "RedPost startet" "RedPost is starting") ($((n * 2)) s)"; sleep 0.25; done
done
[ -t 1 ] && printf '\r\033[K'
# IP fuer Links und Kurzzeit-Eintrag: die oeffentliche nur, wenn sie auf dem Server selbst liegt (VPS).
# Sonst steht der Server hinter einem Router (Heimnetz) — dann die IP, ueber die er ins Netz geht.
ip_pub=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
ip_lan=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)
[ -n "$ip_lan" ] || ip_lan=$(hostname -I 2>/dev/null | awk '{print $1}')
hinter_router=""
if [ -n "$ip_pub" ] && ip -4 addr 2>/dev/null | grep -qF "inet ${ip_pub}/"; then ip="$ip_pub"
elif [ -n "$ip_lan" ]; then ip="$ip_lan"; [ -n "$ip_pub" ] && [ "$ip_pub" != "$ip_lan" ] && hinter_router="ja"
else ip="$ip_pub"; fi
code=$(docker compose logs app 2>/dev/null | grep -o 'Setup-Code: *[A-F0-9]\{4\}-[A-F0-9]\{4\}' | tail -1 | sed 's/.*: *//' || true)
echo ""
if [ -n "$code" ]; then
  kasten "$R" "$(s "Setup-Code" "Setup code"):  $code" "$(s "Brauchst du gleich im Browser." "You need it in the browser in a moment.")"
else
  docker compose logs app 2>/dev/null | grep -A1 -B2 'Setup-Code' | tail -5 || true
fi
echo ""

# 9. Kurzzeit-Link: Port-Modus ohne Domain → die Einrichtung voruebergehend ueber http://<Server-IP> erlauben.
#    Ein eigener Eintrag NUR fuer die IP (andere Domains im Webserver bleiben unberuehrt), geschuetzt durch
#    den Setup-Code; nach der Einrichtung (oder bei Abbruch) wird er wieder entfernt. Wurde im Assistenten
#    eine Domain eingetragen, bekommt sie danach ihren Virtual Host und das Zertifikat.
setup_wert() { docker compose exec -T db psql -U redpost -d redpost -tAc "SELECT coalesce(value->>'$2', '') FROM settings WHERE key = '$1'" 2>/dev/null | tr -d '[:space:]'; }
setup_fertig() { [ "$(setup_wert setup done)" = "true" ]; }
kurz_datei=""; kurz_link=""; kurz_web=""; direkt_url=""
direkt_freigeben() { # App direkt im Netz erreichbar: Port auf allen Schnittstellen statt nur 127.0.0.1
  if grep -q '^RP_BIND=' .env; then sed -i 's|^RP_BIND=.*|RP_BIND=0.0.0.0|' .env; else echo "RP_BIND=0.0.0.0" >> .env; fi
  tu docker compose up -d app >/dev/null 2>&1 || true
  direkt_url="http://${ip}:${PORT}"
  echo ""
  say "==> RedPost ist jetzt direkt erreichbar:  ${direkt_url}" "==> RedPost is now directly reachable:  ${direkt_url}"
  say "    Gib dort den Setup-Code von oben ein und waehle „Nur ueber die IP“. Eine Domain geht spaeter:  sudo bash install.sh --domain post.deinefirma.de" "    Enter the setup code from above there and choose “IP address only”. A domain works later:  sudo bash install.sh --domain mail.example.com"
  say "    Firewall: Port ${PORT}/tcp muss erreichbar sein." "    Firewall: port ${PORT}/tcp must be reachable."
  [ -n "$hinter_router" ] && say "    Von ausserhalb deines Netzes nur mit Portweiterleitung im Router (${ip_pub}:${PORT} → ${ip}:${PORT}) — oder per Cloudflare Tunnel im Panel." "    From outside your network only with port forwarding in your router (${ip_pub}:${PORT} → ${ip}:${PORT}) — or via Cloudflare Tunnel in the panel."
  return 0
}
kurz_weg() {
  [ -n "$kurz_datei" ] || return 0
  if [ "$kurz_web" = "apache2" ]; then a2dissite -q redpost-setup.conf >/dev/null 2>&1 || true; fi
  rm -f "$kurz_datei" ${kurz_link:+"$kurz_link"}
  case "$kurz_web" in nginx) nginx -t >/dev/null 2>&1 && { systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || systemctl start nginx 2>/dev/null || nginx || pkill -HUP -o -x nginx; } ;; apache2) { systemctl reload apache2 2>/dev/null || apache2ctl graceful; } ;; httpd) { systemctl reload httpd 2>/dev/null || httpd -k graceful; } ;; esac
  say "==> Kurzzeit-Eintrag fuer http://${ip} wieder entfernt." "==> Temporary entry for http://${ip} removed again."
  kurz_datei=""
}
# 10. Unter der Domain laeuft schon ein anderer Dienst (eigener Eintrag im Webserver): den fasse ich nicht an —
#     Hinweis, wie die Domain auf RedPost zeigt (Eintrag anpassen oder entfernen, dann install.sh erneut).
fremd_hinweis() {
  echo ""
  say "==> $DOMAIN gehoert in deinem Webserver noch einem anderen Eintrag: $fremd" "==> $DOMAIN still belongs to another entry in your web server: $fremd"
  say "    Den fasse ich nicht an. Entweder dort  proxy_pass http://127.0.0.1:${PORT};  eintragen (plus die Header aus README.md)" "    I will not touch it. Either set  proxy_pass http://127.0.0.1:${PORT};  there (plus the headers from README.md)"
  say "    oder den Eintrag entfernen und  sudo bash install.sh --domain $DOMAIN  erneut ausfuehren." "    or remove the entry and run  sudo bash install.sh --domain $DOMAIN  again."
  return 0
}

# Schon eingerichtet und die Domain gehoert noch einem anderen Dienst? Dann sagen, was zu tun ist.
if [ "$MODUS" = "port" ] && [ -n "$DOMAIN" ] && [ -n "$fremd" ] && [ "${RP_DRY_RUN:-}" != "1" ] && setup_fertig; then
  fremd_hinweis; exit 0
fi

# Kurzzeit-Link auch dann, wenn die Domain noch auf einen anderen Dienst zeigt (Einrichtung erst, dann Hinweis)
if [ "$MODUS" = "port" ] && [ -z "$vhost_angelegt" ] && { [ -z "$DOMAIN" ] || [ -n "$fremd" ]; } && [ "$VHOST" = "ja" ] && [[ "${ip:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "${RP_DRY_RUN:-}" != "1" ] && ! setup_fertig; then
  if command -v nginx >/dev/null 2>&1; then kurz_web="nginx"
  elif command -v apache2ctl >/dev/null 2>&1; then kurz_web="apache2"
  elif command -v httpd >/dev/null 2>&1; then kurz_web="httpd"
  fi
  if [ -n "$kurz_web" ] && ja "==> $(s "Fuer die Einrichtung voruebergehend unter http://${ip} erreichbar machen? (eigener Eintrag nur fuer die IP, wird danach entfernt — bei Nein direkt unter http://${ip}:${PORT})" "Make it reachable at http://${ip} temporarily for the setup? (own entry for the IP only, removed afterwards — if no, directly at http://${ip}:${PORT})")" "j"; then
    if [ "$kurz_web" = "nginx" ]; then
      if [ -d /etc/nginx/sites-enabled ]; then kurz_datei=/etc/nginx/sites-available/redpost-setup.conf; kurz_link=/etc/nginx/sites-enabled/redpost-setup.conf
      else kurz_datei=/etc/nginx/conf.d/redpost-setup.conf; fi
      printf '%s\n' "# RedPost — nur fuer die Einrichtung, entfernt install.sh wieder" "server {" "    listen 80;" "    server_name ${ip}${hinter_router:+ $ip_pub};" "    client_max_body_size 0;" \
        "    location / {" "        proxy_pass http://127.0.0.1:${PORT};" "        proxy_set_header Host \$host;" "        proxy_set_header X-Real-IP \$remote_addr;" \
        "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" "        proxy_set_header X-Forwarded-Proto \$scheme;" "    }" "}" > "$kurz_datei"
      [ -n "$kurz_link" ] && ln -sf "$kurz_datei" "$kurz_link"
      if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || systemctl start nginx 2>/dev/null || nginx || pkill -HUP -o -x nginx; else say "    nginx -t schlaegt fehl — Kurzzeit-Eintrag wieder entfernt." "    nginx -t fails — temporary entry removed again."; kurz_weg; fi
    else
      if [ "$kurz_web" = "apache2" ]; then kurz_datei=/etc/apache2/sites-available/redpost-setup.conf; else kurz_datei=/etc/httpd/conf.d/redpost-setup.conf; fi
      printf '%s\n' "# RedPost — nur fuer die Einrichtung, entfernt install.sh wieder" "<VirtualHost *:80>" "    ServerName ${ip}" ${hinter_router:+"    ServerAlias ${ip_pub}"} "    ProxyPreserveHost On" \
        "    ProxyPass / http://127.0.0.1:${PORT}/" "    ProxyPassReverse / http://127.0.0.1:${PORT}/" "</VirtualHost>" > "$kurz_datei"
      if [ "$kurz_web" = "apache2" ]; then a2enmod -q proxy proxy_http >/dev/null; a2ensite -q redpost-setup.conf >/dev/null; apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 || { say "    Apache-Konfigtest schlaegt fehl — Kurzzeit-Eintrag wieder entfernt." "    Apache config test fails — temporary entry removed again."; kurz_weg; }
      else httpd -t >/dev/null 2>&1 && systemctl reload httpd || { say "    httpd -t schlaegt fehl — Kurzzeit-Eintrag wieder entfernt." "    httpd -t fails — temporary entry removed again."; kurz_weg; }; fi
    fi
    if [ -n "$kurz_datei" ]; then
      trap 'echo; kurz_weg; exit 130' INT TERM
      trap 'kurz_weg' EXIT
      echo ""
      say "==> Oeffne jetzt im Browser:  http://${ip}   und gib den Setup-Code von oben ein." "==> Now open in your browser:  http://${ip}   and enter the setup code from above."
      say "    Waehle im Assistenten „Hinter eigenem Webserver“ und trage deine Domain ein — der Installer" "    In the wizard choose “Behind your web server” and enter your domain — the installer"
      say "    legt danach den Virtual Host und das Zertifikat dafuer an. (Strg+C bricht ab.)" "    then creates the virtual host and the certificate for it. (Ctrl+C cancels.)"
      echo -n "    $(s "Warte auf die Einrichtung" "Waiting for the setup") "
      for _ in $(seq 1 720); do setup_fertig && break; echo -n "."; sleep 10; done
      echo ""
      kurz_weg
      trap - INT TERM EXIT
      if setup_fertig; then
        neu=$(setup_wert net domain | tr 'A-Z' 'a-z' || true)
        if [[ "$neu" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]]; then
          DOMAIN="$neu"
          if grep -q '^RP_PROXY_DOMAIN=' .env; then sed -i "s|^RP_PROXY_DOMAIN=.*|RP_PROXY_DOMAIN=$DOMAIN|" .env; else echo "RP_PROXY_DOMAIN=$DOMAIN" >> .env; fi
          say "==> Einrichtung abgeschlossen. Domain aus dem Assistenten: $DOMAIN" "==> Setup complete. Domain from the wizard: $DOMAIN"
          vhost_einrichten
          if [ -n "$fremd" ]; then fremd_hinweis; exit 0; fi
          if [ -n "$vhost_angelegt" ]; then
            if [ -n "${https_ok:-}" ]; then say "==> Fertig. RedPost laeuft unter  https://${DOMAIN}" "==> Done. RedPost runs at  https://${DOMAIN}"; else say "==> Fertig. RedPost laeuft unter  http://${DOMAIN}  (HTTPS: certbot --nginx -d ${DOMAIN} --redirect)" "==> Done. RedPost runs at  http://${DOMAIN}  (HTTPS: certbot --nginx -d ${DOMAIN} --redirect)"; fi
            exit 0
          fi
        else
          say "==> Einrichtung abgeschlossen, aber ohne Domain. Spaeter:  sudo bash install.sh --domain post.deinefirma.de" "==> Setup complete, but without a domain. Later:  sudo bash install.sh --domain mail.example.com"
          exit 0
        fi
      else
        say "==> Zeit abgelaufen. Einfach nochmal:  sudo bash install.sh" "==> Time is up. Simply run again:  sudo bash install.sh"
        exit 0
      fi
    fi
  else
    direkt_freigeben   # „Nein“ oder kein Webserver: einfach die IP mit dem gewaehlten Port
  fi
fi
if [ -n "$direkt_url" ]; then
  say "==> Fertig. Oeffne im Browser:  ${direkt_url}" "==> Done. Open in your browser:  ${direkt_url}"
elif [ "$MODUS" = "port" ]; then
  if [ -n "$vhost_angelegt" ]; then
    if [ -n "${https_ok:-}" ]; then say "==> Fertig. Oeffne im Browser:  https://${DOMAIN}" "==> Done. Open in your browser:  https://${DOMAIN}"; else say "==> Fertig. Oeffne im Browser:  http://${DOMAIN}" "==> Done. Open in your browser:  http://${DOMAIN}"; fi
  else
    say "==> Fertig. Die App hoert auf 127.0.0.1:${PORT}. Trage in deinem Webserver einen Virtual Host ein:" "==> Done. The app listens on 127.0.0.1:${PORT}. Add a virtual host to your web server:"
    echo ""
    echo "    nginx:                                                 Apache:"
    echo "    server {                                               <VirtualHost *:80>"
    echo "        listen 80;                                             ServerName ${DOMAIN:-mail.example.com}"
    echo "        server_name ${DOMAIN:-mail.example.com};          ProxyPreserveHost On"
    echo "        location / {                                           ProxyPass / http://127.0.0.1:${PORT}/"
    echo "            proxy_pass http://127.0.0.1:${PORT};               ProxyPassReverse / http://127.0.0.1:${PORT}/"
    echo "            proxy_set_header Host \$host;                       RequestHeader set X-Forwarded-Proto \"expr=%{REQUEST_SCHEME}\""
    echo "            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;   </VirtualHost>"
    echo "            proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        }"
    echo "    }"
    echo ""
    say "    HTTPS danach z. B. mit:  certbot --nginx -d ${DOMAIN:-mail.example.com} --redirect" "    HTTPS afterwards e.g. with:  certbot --nginx -d ${DOMAIN:-mail.example.com} --redirect"
    say "    Und HSTS im HTTPS-Eintrag:  nginx  add_header Strict-Transport-Security \"max-age=31536000\" always;   Apache  Header always set Strict-Transport-Security \"max-age=31536000\"" "    And HSTS in the HTTPS entry:  nginx  add_header Strict-Transport-Security \"max-age=31536000\" always;   Apache  Header always set Strict-Transport-Security \"max-age=31536000\""
    say "    Zum Ausprobieren ohne Domain:  ssh -L ${PORT}:127.0.0.1:${PORT} root@${ip}  und dann  http://127.0.0.1:${PORT}" "    To try it without a domain:  ssh -L ${PORT}:127.0.0.1:${PORT} root@${ip}  and then  http://127.0.0.1:${PORT}"
  fi
  say "    Im Assistenten ist „Hinter eigenem Webserver“ mit deiner Domain schon vorgewaehlt." "    In the wizard, “Behind your web server” with your domain is already preselected."
else
  say "==> Fertig. Oeffne im Browser:  http://${ip}" "==> Done. Open in your browser:  http://${ip}"
  say "    Firewall: Port 80 und 443 muessen von aussen erreichbar sein." "    Firewall: port 80 and 443 must be reachable from outside."
fi
say "    Den Setup-Code siehst du oben (oder: docker compose logs app | grep Setup-Code)." "    You can see the setup code above (or: docker compose logs app | grep Setup-Code)."
# Abschluss: Adresse noch einmal gross
ziel_url=""
if [ -n "$direkt_url" ]; then ziel_url="$direkt_url"
elif [ "$MODUS" = "port" ] && [ -n "${vhost_angelegt:-}" ] && [ -n "${DOMAIN:-}" ]; then ziel_url="$([ -n "${https_ok:-}" ] && echo https || echo http)://${DOMAIN}"
elif [ "$MODUS" != "port" ]; then ziel_url="http://${ip}"; fi
if [ -n "$ziel_url" ]; then echo ""; kasten "$G" "RedPost  ${Z_PUNKT}  $ziel_url"; fi
echo ""
