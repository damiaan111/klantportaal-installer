#!/usr/bin/env bash
#
# Klantportaal, installatielogica die BINNEN de container draait.
# Wordt aangeroepen door ct/klantportaal.sh. Draai dit niet zelf.
#
# Verwacht deze omgevingsvariabelen:
#   KP_REPO_SSH        git@github.com:owner/naam.git
#   KP_PUBLIEKE_HOST   de publieke hostname van het portaal
#   KP_TUNNEL_IP       IP van de cloudflared-container, mag leeg zijn
#   KP_CONTACT_MAIL    adres voor bestanden, mag leeg zijn
#   KP_MAX_UPLOAD_MB   grootste bestand dat een klant mag uploaden
#   KP_QUOTA_GB        opslag per klant
#
set -euo pipefail

GN=$'\033[32m'; BL=$'\033[36m'; RD=$'\033[31m'; BO=$'\033[1m'; CL=$'\033[0m'
stap() { echo -e "  ${BL}==>${CL} ${BO}$*${CL}"; }
ok()   { echo -e "  ${GN}  ok${CL} $*"; }
fout() { echo -e "  ${RD} err${CL} $*" >&2; exit 1; }

: "${KP_REPO_SSH:?KP_REPO_SSH ontbreekt}"
: "${KP_PUBLIEKE_HOST:?KP_PUBLIEKE_HOST ontbreekt}"
KP_TUNNEL_IP="${KP_TUNNEL_IP:-}"
KP_CONTACT_MAIL="${KP_CONTACT_MAIL:-}"
KP_MAX_UPLOAD_MB="${KP_MAX_UPLOAD_MB:-2048}"
KP_QUOTA_GB="${KP_QUOTA_GB:-5}"

export DEBIAN_FRONTEND=noninteractive

APP_DIR=/opt/klantportaal
APP_USER=klantportaal
KEY_BRON=/root/.ssh/klantportaal_deploy
KEY_DOEL=/etc/klantportaal/deploy_key
DB_NAAM=portaal

# Uploads staan BUITEN de map met de code. Dat is geen smaak: `update`
# weigert te draaien als er lokale wijzigingen in de git-map staan, en
# een map met uploads erin is precies zo'n wijziging. In /opt zetten
# betekent dat je nooit meer kunt bijwerken.
UPLOAD_DIR=/var/lib/klantportaal/uploads

# ── 1. Basispakketten
stap "Basispakketten installeren"
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg git openssl nftables locales tzdata \
  sudo openssh-client >/dev/null
ok "gereed"

# Nederlandse tijdzone, want het portaal toont tijden in Europe/Amsterdam
# en een container met UTC maakt het opzoeken van een fout onnodig lastig.
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
echo "Europe/Amsterdam" > /etc/timezone

# ── 2. Node.js 22
stap "Node.js 22 installeren"
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 \
    || fout "NodeSource toevoegen mislukt"
  apt-get install -y -qq nodejs >/dev/null || fout "Node installeren mislukt"
fi
NODE_V=$(node -v)
[[ "${NODE_V#v}" == 2[2-9]* || "${NODE_V#v}" == [3-9][0-9]* ]] \
  || fout "Node ${NODE_V} is te oud, het project eist minstens 22"
ok "${NODE_V}"

# ── 3. PostgreSQL 17
#
# Via de PGDG-repository en niet wat het besturingssysteem meelevert.
# Debian 12 heeft 15 en Debian 13 heeft 17, en dit script moet op beide
# hetzelfde resultaat geven.
stap "PostgreSQL 17 installeren"
if ! command -v psql >/dev/null 2>&1; then
  . /etc/os-release
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    || fout "PGDG-sleutel ophalen mislukt"
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq postgresql-17 >/dev/null || fout "Postgres 17 installeren mislukt"
fi
systemctl enable --now postgresql >/dev/null 2>&1 || true
for _i in $(seq 1 30); do
  su - postgres -c "pg_isready -q" >/dev/null 2>&1 && break
  sleep 1
done
su - postgres -c "pg_isready -q" || fout "Postgres start niet"
ok "$(su - postgres -c 'psql -tAc "select version()"' | cut -d, -f1)"

# ── 4. Geheimen
stap "Wachtwoorden en tokens genereren"
gen() { openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-32; }
PG_SUPER_PW=$(gen); APP_PW=$(gen); AUTH_PW=$(gen); STUDIO_PW=$(gen); ADMIN_TOKEN=$(gen)
ok "vijf willekeurige waarden, alleen in ${APP_DIR}/.env"

# ── 5. Database met de juiste collatie
#
# DIT IS HET ONDERDEEL DAT LATER NIET TE WIJZIGEN IS. De collatie van een
# database ligt vast zodra hij bestaat, en veranderen betekent
# dump-en-restore. Zie docs/kritieke-instellingen.md.
#
# ICU met nl-NL zorgt voor taalkundig correcte sortering die op elk
# platform hetzelfde is. Zonder dit sorteert Postgres op byte-orde en
# staan klantnamen met diakrieten op de verkeerde plek.
stap "Database aanmaken met ICU-collatie nl-NL"
su - postgres -c "psql -q -c \"ALTER USER postgres WITH PASSWORD '${PG_SUPER_PW}'\"" \
  || fout "Wachtwoord voor postgres zetten mislukt"

if su - postgres -c "psql -tAc \"select 1 from pg_database where datname='${DB_NAAM}'\"" | grep -q 1; then
  ok "database ${DB_NAAM} bestond al, ongemoeid gelaten"
else
  su - postgres -c "psql -q -v ON_ERROR_STOP=1 -c \"CREATE DATABASE ${DB_NAAM} TEMPLATE template0 ENCODING 'UTF8' LOCALE_PROVIDER icu ICU_LOCALE 'nl-NL' LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8'\"" \
    || fout "Database aanmaken mislukt"
fi

# Controleren in plaats van aannemen. Staat dit verkeerd, dan is het later
# alleen met dump-en-restore te herstellen, dus stop nu liever.
PROV=$(su - postgres -c "psql -tAc \"select datlocprovider from pg_database where datname='${DB_NAAM}'\"")
[[ "$PROV" == "i" ]] || fout "Database ${DB_NAAM} gebruikt niet de ICU-collatie (${PROV}). Verwijder de database en draai dit script opnieuw."
ok "collatie ICU nl-NL, gecontroleerd"

# ── 6. Applicatiegebruiker
stap "Gebruiker ${APP_USER} aanmaken"
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/${APP_USER} \
          --shell /bin/bash "$APP_USER"
fi
install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
# 700: alleen de applicatiegebruiker komt bij de bestanden van klanten.
install -d -m 700 -o "$APP_USER" -g "$APP_USER" "$UPLOAD_DIR"
ok "draait niet als root, uploads in ${UPLOAD_DIR}"

# ── 7. Deploy key en de code
stap "Code ophalen uit de private repo"
[[ -f "$KEY_BRON" ]] || fout "Deploy key niet gevonden op ${KEY_BRON}"
install -d -m 700 /etc/klantportaal
install -m 600 -o "$APP_USER" -g "$APP_USER" "$KEY_BRON" "$KEY_DOEL"
shred -u "$KEY_BRON" 2>/dev/null || rm -f "$KEY_BRON"

# Hostsleutel van GitHub vastleggen in plaats van blind vertrouwen.
install -d -m 700 -o "$APP_USER" -g "$APP_USER" /var/lib/${APP_USER}/.ssh
ssh-keyscan -t ed25519 github.com 2>/dev/null > /var/lib/${APP_USER}/.ssh/known_hosts \
  || fout "Hostsleutel van github.com ophalen mislukt"
chown "$APP_USER:$APP_USER" /var/lib/${APP_USER}/.ssh/known_hosts
chmod 600 /var/lib/${APP_USER}/.ssh/known_hosts

export GIT_SSH_COMMAND="ssh -i ${KEY_DOEL} -o IdentitiesOnly=yes -o UserKnownHostsFile=/var/lib/${APP_USER}/.ssh/known_hosts"
if [[ -d "${APP_DIR}/.git" ]]; then
  ok "repo bestond al"
else
  sudo -u "$APP_USER" -H env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" \
    git clone --depth 1 "$KP_REPO_SSH" "$APP_DIR" >/dev/null 2>&1 \
    || fout "Klonen mislukt. Staat de deploy key wel op GitHub? Zie de vorige stap."
fi
ok "$(sudo -u "$APP_USER" git -C "$APP_DIR" log --oneline -1)"

# ── 8. Afhankelijkheden
#
# Volledige npm ci, dus GEEN --omit=dev. Het project start via tsx, en
# tsx staat bij de devDependencies. Daar loopt zo'n installatie normaal
# op stuk, met een foutmelding die niet uitlegt waarom.
stap "npm-afhankelijkheden installeren"
sudo -u "$APP_USER" -H bash -c "cd '$APP_DIR' && npm ci --no-audit --no-fund" >/dev/null 2>&1 \
  || fout "npm ci mislukt"
ok "gereed"

# ── 9. Configuratie
stap "Configuratie schrijven"
cat > "${APP_DIR}/.env" <<ENVEOF
# Aangemaakt door de Proxmox-installatie. Alle geheimen hieronder zijn
# eenmalig willekeurig gegenereerd en staan nergens anders.

# Superuser. Alleen migraties en seeds gebruiken deze verbinding.
# Een superuser omzeilt RLS ALTIJD, dus de applicatie mag hem niet kennen.
ADMIN_DATABASE_URL=postgres://postgres:${PG_SUPER_PW}@localhost:5432/${DB_NAAM}

# De rol app_user: NOSUPERUSER, NOBYPASSRLS. Dit is de enige verbinding
# die applicatiecode gebruikt.
DATABASE_URL=postgres://app_user:${APP_PW}@localhost:5432/${DB_NAAM}

# app_auth en app_studio worden begrensd door GRANTs in plaats van RLS.
AUTH_DATABASE_URL=postgres://app_auth:${AUTH_PW}@localhost:5432/${DB_NAAM}
STUDIO_DATABASE_URL=postgres://app_studio:${STUDIO_PW}@localhost:5432/${DB_NAAM}

# scripts/migrate.ts zet de rolwachtwoorden hieruit.
APP_DB_PASSWORD=${APP_PW}
AUTH_DB_PASSWORD=${AUTH_PW}
STUDIO_DB_PASSWORD=${STUDIO_PW}

# Toegang tot /studio. Fase-1-steiger, geen productiemechanisme. Zet
# /studio achter Cloudflare Access met Entra ID zodra je tenant er staat.
# Zie paragraaf 9 van docs/kritieke-instellingen.md.
ADMIN_TOKEN=${ADMIN_TOKEN}

# Bepaalt de links in de inlogmail. Moet kloppen met je tunnel.
PORTAL_BASE_URL=https://${KP_PUBLIEKE_HOST}

# Adres waar klanten voorlopig bestanden naartoe mailen.
PORTAL_CONTACT_EMAIL=${KP_CONTACT_MAIL}

# BEWUSTE KEUZE: wijder dan loopback, want de cloudflared-container is
# een aparte container en moet hierbij kunnen. De firewallregel in
# /etc/nftables.conf beperkt wie dat mag. Zonder die regel mag heel je LAN
# erbij, en dan is /studio bereikbaar voor elk apparaat in je netwerk.
HOST=0.0.0.0
PORT=3000

# Bijlagen. Deze map staat BUITEN de git-map, anders weigert `update`.
UPLOAD_DIR=${UPLOAD_DIR}

# Grootste bestand per upload. De applicatie houdt daarnaast zelf
# ruimte vrij voor de database en weigert uploads voordat de schijf
# vol is. Zie src/platform/storage/ruimte.ts.
MAX_UPLOAD_BYTES=$(( KP_MAX_UPLOAD_MB * 1024 * 1024 ))
ENVEOF
chown "$APP_USER:$APP_USER" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"
ok "${APP_DIR}/.env, alleen leesbaar voor ${APP_USER}"

# ── 10. Migraties
stap "Migraties uitvoeren"
sudo -u "$APP_USER" -H bash -c "cd '$APP_DIR' && npm run migrate" 2>&1 | sed 's/^/       /' \
  || fout "Migraties mislukt"
ok "schema en RLS-policies staan"

# Het quotum heeft een standaard uit de migratie. Hier wordt die op
# jouw keuze gezet, ook voor klanten die er later bij komen.
QUOTA_BYTES=$(( KP_QUOTA_GB * 1024 * 1024 * 1024 ))
su - postgres -c "psql -q -d ${DB_NAAM} -c \"ALTER TABLE customer ALTER COLUMN storage_quota_bytes SET DEFAULT ${QUOTA_BYTES}\"" \
  || fout "Quotum instellen mislukt"
ok "opslag per klant: ${KP_QUOTA_GB} GB"

# ── 11. Service
stap "systemd-service installeren"
cat > /etc/systemd/system/klantportaal.service <<'SVCEOF'
[Unit]
Description=Klantportaal
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=klantportaal
Group=klantportaal
WorkingDirectory=/opt/klantportaal
ExecStart=/usr/bin/npm run start
Restart=always
RestartSec=5

# Het opstartbericht verzwijgt het studio-token zodra de uitvoer geen
# terminal is, en dat is hier zo. Wat hier WEL in terechtkomt zolang er
# geen SMTP is: de inloglinks. Wie dit journaal kan lezen, kan inloggen
# als een klant. Zie paragraaf 8 van docs/kritieke-instellingen.md.
StandardOutput=journal
StandardError=journal
SyslogIdentifier=klantportaal

NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable --now klantportaal >/dev/null 2>&1 || fout "Service start niet"
sleep 4
systemctl is-active --quiet klantportaal \
  || fout "Service is niet actief. Kijk met: journalctl -u klantportaal -n 40"
ok "klantportaal.service actief"

# ── 12. Firewall
stap "Firewall instellen"
if [[ -n "$KP_TUNNEL_IP" ]]; then
  # Bewust GEEN default-drop. Een firewall die ik hier niet kan testen en
  # die alles dichtzet, is een firewall die je buiten je eigen container
  # kan sluiten. Dus alleen poort 3000 afschermen, en de rest ongemoeid.
  cat > /etc/nftables.conf <<NFTEOF
#!/usr/sbin/nft -f
# Alleen poort 3000 afschermen. Het portaal serveert daar gewone HTTP
# zonder TLS, dus alleen de cloudflared-container mag erbij. Die regelt
# de HTTPS, en zonder HTTPS werkt inloggen niet eens.
flush ruleset

table inet klantportaal {
  chain input {
    type filter hook input priority 0; policy accept;

    iif lo accept
    ip saddr ${KP_TUNNEL_IP} tcp dport 3000 accept
    ct state established,related accept
    tcp dport 3000 drop
  }
}
NFTEOF
  chmod 755 /etc/nftables.conf
  systemctl enable nftables >/dev/null 2>&1 || true
  nft -f /etc/nftables.conf || fout "Firewallregel toepassen mislukt"
  ok "poort 3000 alleen vanaf ${KP_TUNNEL_IP}"
else
  ok "geen tunnel-IP opgegeven, poort 3000 staat open op je LAN"
  echo -e "       ${RD}Let op: /studio is dan bereikbaar voor elk apparaat in je netwerk.${CL}"
fi

# ── 13. Het update-commando
stap "Commando 'update' installeren"
cat > /usr/local/bin/update <<'UPDEOF'
#!/usr/bin/env bash
#
# Klantportaal bijwerken. Draai dit in de console van de container.
#
# Waarom dit bestaat en niet het installatiescript opnieuw: hier zit een
# database met klantdata onder. Een installatiescript dat ook kan updaten
# is een installatiescript dat je database kan wissen.
#
set -euo pipefail

GN=$'\033[32m'; BL=$'\033[36m'; RD=$'\033[31m'; YW=$'\033[33m'; BO=$'\033[1m'; CL=$'\033[0m'
stap() { echo -e "  ${BL}==>${CL} ${BO}$*${CL}"; }
ok()   { echo -e "  ${GN}  ok${CL} $*"; }
fout() { echo -e "  ${RD} err${CL} $*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || fout "Draai dit als root"

APP_DIR=/opt/klantportaal
APP_USER=klantportaal
BACKUP_DIR=/var/backups/klantportaal
KEY=/etc/klantportaal/deploy_key
export GIT_SSH_COMMAND="ssh -i ${KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=/var/lib/${APP_USER}/.ssh/known_hosts"

# Eigen wijzigingen zouden door een pull worden overschreven of de pull
# laten falen. Beter nu stoppen met een duidelijke melding.
if [[ -n "$(sudo -u $APP_USER git -C "$APP_DIR" status --porcelain)" ]]; then
  echo -e "  ${YW}Er staan lokale wijzigingen in ${APP_DIR}:${CL}"
  sudo -u $APP_USER git -C "$APP_DIR" status --short | sed 's/^/       /'
  fout "Zet die eerst terug met: git -C ${APP_DIR} checkout ."
fi

HUIDIG=$(sudo -u $APP_USER git -C "$APP_DIR" rev-parse --short HEAD)

# ── Eerst een dump, dan pas iets aanraken.
#
# Een migratie die op echte klantdata misgaat, moet terug te draaien
# zijn. Dit is de enige stap in dit script die je niet kunt overslaan.
stap "Database veiligstellen"
install -d -m 700 "$BACKUP_DIR"
DUMP="${BACKUP_DIR}/voor-update-$(date +%Y%m%d-%H%M%S).sql.gz"
su - postgres -c "pg_dump portaal" | gzip > "$DUMP" || fout "pg_dump mislukt, er is niets gewijzigd"
chmod 600 "$DUMP"
ok "$DUMP ($(du -h "$DUMP" | cut -f1))"

stap "Nieuwe versie ophalen"
sudo -u $APP_USER -H env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" \
  git -C "$APP_DIR" fetch --quiet origin main || fout "Ophalen mislukt"
NIEUW=$(sudo -u $APP_USER git -C "$APP_DIR" rev-parse --short origin/main)

if [[ "$HUIDIG" == "$NIEUW" ]]; then
  ok "al op de nieuwste versie (${HUIDIG}), niets te doen"
  rm -f "$DUMP"
  exit 0
fi

sudo -u $APP_USER -H env GIT_SSH_COMMAND="$GIT_SSH_COMMAND" \
  git -C "$APP_DIR" merge --ff-only --quiet origin/main \
  || fout "Kon niet vooruitspoelen. Bekijk: git -C ${APP_DIR} log --oneline -5"
ok "${HUIDIG} wordt ${NIEUW}"

stap "Afhankelijkheden bijwerken"
sudo -u $APP_USER -H bash -c "cd '$APP_DIR' && npm ci --no-audit --no-fund" >/dev/null 2>&1 \
  || fout "npm ci mislukt"
ok "gereed"

# Migraties zijn onveranderlijk zodra ze zijn toegepast. Heeft iemand een
# bestaande migratie aangeraakt, dan weigert de migrator op de checksum.
# Dat is precies goed, en dan hoort update daarop te stoppen in plaats van
# half door te gaan.
stap "Migraties uitvoeren"
if ! sudo -u $APP_USER -H bash -c "cd '$APP_DIR' && npm run migrate" 2>&1 | sed 's/^/       /'; then
  echo ""
  echo -e "  ${RD}De migraties zijn mislukt. De code staat op ${NIEUW}, de database niet.${CL}"
  echo -e "  ${RD}Terugzetten: ${BO}gunzip -c ${DUMP} | su - postgres -c 'psql portaal'${CL}"
  exit 1
fi
ok "database bijgewerkt"

stap "Service herstarten"
systemctl restart klantportaal
sleep 4
systemctl is-active --quiet klantportaal \
  || fout "Service komt niet op. Kijk met: journalctl -u klantportaal -n 40"
ok "actief"

echo ""
echo -e "  ${GN}${BO}Bijgewerkt naar ${NIEUW}.${CL}"
echo -e "  Dump van voor de update: ${DUMP}"
echo ""
UPDEOF
chmod 755 /usr/local/bin/update
ok "typ 'update' in deze container om bij te werken"

# ── 14. Seed-commando
cat > /usr/local/bin/klantportaal-seed <<'SEEDEOF'
#!/usr/bin/env bash
# Demodata in de database zetten. LET OP: dit maakt de bestaande tabellen
# leeg. Gebruik dit alleen op een testopstelling.
set -euo pipefail
[[ "$(id -u)" == "0" ]] || { echo "Draai dit als root" >&2; exit 1; }
echo "Dit WIST de huidige data en zet demoklanten terug."
read -r -p "Doorgaan? [j/N]: " a
[[ "${a,,}" =~ ^(j|ja|y|yes)$ ]] || { echo "Geannuleerd."; exit 0; }
cd /opt/klantportaal && sudo -u klantportaal -H npm run seed
SEEDEOF
chmod 755 /usr/local/bin/klantportaal-seed

# ── 15. Nachtelijke back-up
stap "Nachtelijke back-up instellen"
cat > /etc/systemd/system/klantportaal-backup.service <<'BAKEOF'
[Unit]
Description=Klantportaal database back-up
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/klantportaal-backup
BAKEOF

cat > /usr/local/bin/klantportaal-backup <<'BAKSHEOF'
#!/usr/bin/env bash
set -euo pipefail
DIR=/var/backups/klantportaal
install -d -m 700 "$DIR"
DUMP="${DIR}/nacht-$(date +%Y%m%d-%H%M%S).sql.gz"
su - postgres -c "pg_dump portaal" | gzip > "$DUMP"
chmod 600 "$DUMP"
# Zeven nachten bewaren. Dit is een back-up tegen een misgelopen migratie
# of een verkeerde handeling, niet tegen brand. Zet dit pad in je
# Proxmox-back-up als je het echt wil bewaren.
find "$DIR" -name 'nacht-*.sql.gz' -mtime +7 -delete
BAKSHEOF
chmod 755 /usr/local/bin/klantportaal-backup

cat > /etc/systemd/system/klantportaal-backup.timer <<'TIMEOF'
[Unit]
Description=Klantportaal database back-up, elke nacht

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
TIMEOF
systemctl daemon-reload
systemctl enable --now klantportaal-backup.timer >/dev/null 2>&1 || true
ok "elke nacht 03:30, zeven nachten bewaard in /var/backups/klantportaal"

echo ""
ok "${BO}Installatie voltooid.${CL}"
