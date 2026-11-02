# RedPost

**Selbst gehostete E-Mail mit Kalender und Kontakten**: ein schnelles Webmail für deine bisherigen Postfächer – oder gleich mit eigenem Mailserver für deine Domains. RedPost läuft als Docker-Paket auf deinem Server und holt das HTTPS-Zertifikat selbst.

By [TheRedStonee](https://www.theredstonee.de/) · komplett kostenlos, ohne Lizenzschlüssel

> **English:** Self-hosted e-mail with calendar and contacts. A fast webmail for your existing mailboxes (IMAP/SMTP) – or with a built-in mail server (docker-mailserver: Postfix, Dovecot, Rspamd, DKIM) for your own domains. Conversations, full-text search, labels, snooze, follow-up reminders, focus mode, filters and out-of-office via Sieve, phishing warnings, tracking protection, disposable addresses, confidential e-mails with expiry, PGP encryption in the browser, CalDAV/CardDAV sync with phones and desktop apps, installable as an app with push notifications. One `docker compose up`, automatic HTTPS via Let's Encrypt. German and English. Jump to [Quick start](#schnellstart).

---

## Was es kann

**Post**
- Konversationen, Volltextsuche über alle Ordner (`von:`, `betreff:`, `hat:anhang` …), Etiketten, Tastenkürzel und Befehlsleiste (Strg+K)
- Zurückstellen, später senden, Rückgängig, Erinnern wenn keine Antwort kommt, Signaturen, Vorlagen, Lesebestätigung
- Fokus-Modus: Menschen zuerst, Newsletter, Benachrichtigungen und Rechnungen gebündelt
- Newsletter-Aufräumer (Abmelden mit einem Klick), Anhang-Zentrale, Wegwerf-Adressen je Dienst
- Filter und Abwesenheit – mit Sieve direkt auf dem Mailserver, sonst beim Abruf

**Schutz**
- Phishing-Warnung (ähnliche Domains, SPF/DKIM/DMARC, riskante Links und Anhänge), Zählpixel blockiert, Bilder über einen eigenen Proxy
- Vertrauliche Mails: Empfänger lesen auf einer geschützten Seite, mit Ablauf, „nur einmal“, Kennwort und sicherer Antwort
- PGP-Verschlüsselung im Browser (OpenPGP, Autocrypt, Schlüsselsuche über WKD und keys.openpgp.org)
- Anmeldung mit Zwei-Faktor oder Passkey als zweitem Schritt

**Kalender & Kontakte**
- Monats-, Wochen- und Listenansicht, Serien, Erinnerungen, Einladungen per Mail (zusagen direkt aus der Mail)
- Abgleich mit iPhone, Android (DAVx⁵), Thunderbird und Outlook über CalDAV/CardDAV – mit eigenem Geräte-Passwort je Gerät

**Mailserver (optional)**
- docker-mailserver mit Postfix, Dovecot, Rspamd, DKIM; Domains, Postfächer, Aliase, Weiterleitungen, Kontingente
- DNS-Assistent (auch automatisch über Cloudflare), Zustellbarkeits-Monitor (Sperrlisten, DNS, Zertifikat, Warteschlange)
- Umzug vom alten Anbieter (komplette IMAP-Übernahme im Hintergrund), tägliche Postfach-Sicherung mit Wiederherstellen

### Für Teams, Vereine und Anbieter

- **Mehrere Mailserver** und fremde Server nebeneinander
- **Anbieter-Modus:** Organisationen mit eigenen Domains, Kontingenten und Admins, Selbstbedienung mit eigenem Logo
- **Gemeinsame Postfächer** mit Zuweisung, internen Notizen und „wer antwortet gerade“
- **Eigene Marke** (Logo, Name, Farben) und **mehrere App-Server** (`compose.node.yml`)

## Voraussetzungen

| | Minimum | Empfohlen |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 1 GB (nur Webmail) | 4 GB mit eigenem Mailserver (mit ClamAV 6 GB) |
| Speicher | 5 GB | je nach Postfächern |

- Ein Linux-Server (Debian oder Ubuntu) mit Root-Zugriff.
- Port **80** und **443** von außen erreichbar – oder ein vorhandener nginx/Apache, hinter den sich RedPost hängt.
- Für HTTPS eine (Sub-)Domain, deren DNS-A-Eintrag auf den Server zeigt.
- **Eigener Mailserver:** eine öffentliche IP mit offenen Ports **25, 465, 587, 993** (und 4190 für Sieve-Programme), ein PTR-Eintrag (Reverse-DNS) auf den Namen des Mailservers. Viele Heim-Anschlüsse und manche Cloud-Anbieter sperren Port 25.

## Schnellstart

```bash
curl -fsSL https://raw.githubusercontent.com/theredstonee/redpost-docker/main/install.sh | sudo bash
```

Das Skript
- legt alles nach **`/opt/redpost`** (anderer Ordner: `curl … | sudo RP_DIR=/srv/redpost bash`),
- installiert Docker, falls nötig,
- erzeugt ein Datenbank-Passwort und startet alles,
- richtet den Update-Dienst ein und zeigt am Ende die Adresse und den **Setup-Code**.

Öffne die Adresse im Browser und folge dem Assistenten. Dort wählst du, ob RedPost die Postfächer bei deinem bisherigen Anbieter nutzt (der Assistent erkennt die Server zu den meisten Adressen selbst) oder einen eigenen Mailserver bekommt.

<details>
<summary>Lieber von Hand?</summary>

```bash
mkdir redpost && cd redpost
for f in docker-compose.yml compose.caddy.yml compose.port.yml compose.mail.yml compose.mail-caddy.yml compose.mail-le.yml radicale.conf Caddyfile .env.example; do curl -fsSLO "https://raw.githubusercontent.com/theredstonee/redpost-docker/main/$f"; done
cp .env.example .env
nano .env                # DB_PASSWORD setzen (lang und zufällig)
docker compose up -d
docker compose logs app | grep Setup-Code
```

Danach `http://<IP-deines-Servers>` im Browser öffnen. Ohne Update-Dienst (`install.sh`) startet der Knopf „Mailserver einschalten“ den Container nicht selbst – dann `compose.mail.yml` in `COMPOSE_FILE` ergänzen, `RP_MAIL_HOST` setzen und `docker compose up -d`.
</details>

### Domain und HTTPS

Im Assistenten gibst du deine Domain ein. Er zeigt die erkannte Server-IP und den nötigen DNS-Eintrag, prüft ihn und holt das Zertifikat. Bei **Cloudflare** den Proxy für diese Domain ausschalten (graue Wolke), sonst kann das Zertifikat nicht ausgestellt werden.

### Hinter deinem eigenen Webserver

Läuft auf dem Server schon nginx, Apache oder Plesk auf Port 80/443, richtet `install.sh` RedPost **ohne eigenen Caddy** ein: die App bekommt einen freien Port auf `127.0.0.1`, auf Nachfrage legt das Skript den Virtual Host an und holt per `certbot` das Zertifikat. Ohne Nachfragen:

```bash
sudo bash install.sh --port 8080 --domain post.deinefirma.de --email du@deinefirma.de
```

`--no-vhost` lässt den Webserver unangetastet, `--caddy` erzwingt den eigenen Caddy. Legst du den Eintrag selbst an, braucht er diese Header:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    client_max_body_size 50m;
}
```

### Cloudflare Tunnel (ohne offene Ports)

Für das Webmail allein reicht auch ein Cloudflare Tunnel (Panel → **Einstellungen → Installation → Cloudflare Tunnel**). Ein **eigener Mailserver** geht darüber nicht – Mails brauchen direkt erreichbare Ports.

## Eigener Mailserver

Panel → **Verwaltung → Domains & Mailserver → Einschalten**: Name des Mailservers (z. B. `mail.deinefirma.de`) und erste Domain eintragen. Der Update-Dienst startet docker-mailserver, RedPost legt den Postmaster an und schreibt Konten, Aliase, DKIM, Filter und Spam-Regeln selbst.

- **Zertifikat:** mit eigenem Caddy holt Caddy es für den Mailserver-Namen, hinter nginx/Apache `certbot`. Bis dahin nutzt der Mailserver ein selbst erzeugtes Zertifikat (Mailprogramme warnen dann).
- **DNS:** der **DNS-Assistent** zeigt je Domain die nötigen Einträge (MX, SPF, DKIM, DMARC, Autoconfig) und prüft sie – mit Cloudflare-Token trägt er sie auf Wunsch selbst ein.
- **Reverse-DNS (PTR):** beim Server-Anbieter auf den Namen des Mailservers setzen – sonst landen Mails oft im Spam.

## Kalender & Kontakte auf Handy und PC

Einstellungen → **Kalender & Kontakte** zeigt Server-Adresse, Benutzername und Anleitungen; dort erzeugst du je Gerät ein eigenes **Geräte-Passwort** (das Postfach-Passwort gilt hier bewusst nicht). Die Kalender selbst liegen im Container `radicale`, der nur über RedPost erreichbar ist.

## Update

Im Panel: unten links steht die Version – ein roter Punkt heißt „neue Version da“, Klick → **Jetzt aktualisieren**. Das holt das neue Image, die aktuellen Compose-Dateien und bringt auch den Update-Dienst auf den neuesten Stand. Auf dem Server geht dasselbe mit einem Befehl (fragt nichts, lässt `.env`, Daten und Domain, wie sie sind):

```bash
curl -fsSL https://raw.githubusercontent.com/theredstonee/redpost-docker/main/update.sh | sudo bash
```

## Mehrere App-Server

Weitere App-Server für dieselbe Installation: siehe `compose.node.yml`.

## Sicherung

- **Postfächer (eigener Mailserver):** Verwaltung → **Sicherung** – täglich automatisch, Wiederherstellen auch durch die Nutzer selbst.
- **Von Hand:** Datenbank `docker compose exec db pg_dump -U redpost redpost > redpost.sql`, dazu die Volumes `maildaten` (Mails), `mailkonfig` (Konten, DKIM), `radicale` (Kalender, Kontakte) und `daten`.

## Entfernen

```bash
sudo bash /opt/redpost/install.sh --deinstallieren
```

Stoppt und entfernt die Container und die Webserver-Einträge von RedPost. Mails, Datenbank und Ordner werden nur nach einer Rückfrage und dem Eintippen von `loeschen` gelöscht.

## Hilfe

- **Zwei-Faktor-Gerät verloren und keine Notfall-Codes:** den Container einmal mit `RP_RESET_2FA=<benutzername>` in der `.env` starten (`docker compose up -d`), danach die Zeile wieder entfernen.
- **Setup-Code nicht mehr da:** `docker compose logs app | grep Setup-Code`
- **Logs:** `docker compose logs -f app` bzw. `docker compose logs -f mail`

---

RedPost ist ein Produkt von [TheRedStonee](https://www.theredstonee.de/). Der Quelltext ist nicht öffentlich; dieses Repository enthält die Installationsdateien für das Docker-Image `ghcr.io/theredstonee/redpost`. Der eigene Mailserver nutzt [docker-mailserver](https://github.com/docker-mailserver/docker-mailserver) (MIT), Kalender und Kontakte [Radicale](https://radicale.org) (GPLv3) als eigene, unveränderte Container.
