#!/usr/bin/env bash
#
# Klantportaal, LXC installer voor Proxmox VE
#
# Generiek: dit script bevat geen repo, domein of adres. Die vraagt
# hij tijdens de installatie, zodat er in dit publieke bestand niets
# staat over wie hem gebruikt of waarvoor.
#
# Draai dit op je Proxmox host als root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/damiaan111/klantportaal-installer/main/klantportaal/main/ct/klantportaal.sh)"
#
# Dit script maakt een NIEUWE container. Wil je een bestaande installatie
# bijwerken, gebruik dan `update` in de console van die container. Dat is
# een bewust verschil: hier zit een database met klantdata onder, en een
# installatiescript dat ook kon updaten is een installatiescript dat je
# database kan wissen.
#
set -euo pipefail

# ── Kleuren
RD=$'\033[31m'; GN=$'\033[32m'; YW=$'\033[33m'; BL=$'\033[36m'
BO=$'\033[1m';  DIM=$'\033[2m'; CL=$'\033[0m'

msg_info()  { echo -e " ${BL}[INFO]${CL}  $*" >&2; }
msg_ok()    { echo -e " ${GN}[ OK ]${CL}  $*" >&2; }
msg_warn()  { echo -e " ${YW}[LET OP]${CL} $*" >&2; }
msg_error() { echo -e " ${RD}[ERR ]${CL}  $*" >&2; exit 1; }

ask() {
  local label="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    echo -en " ${YW}▶${CL}  ${BO}$(printf '%-30s' "$label")${CL} ${DIM}[${default}]${CL}: " > /dev/tty
  else
    echo -en " ${YW}▶${CL}  ${BO}$(printf '%-30s' "$label")${CL}: " > /dev/tty
  fi
  read -r value < /dev/tty
  echo "${value:-$default}"
}

confirm() {
  local label="$1" value
  echo -en " ${YW}▶${CL}  ${BO}$(printf '%-30s' "$label")${CL} ${DIM}[j/N]${CL}: " > /dev/tty
  read -r value < /dev/tty
  [[ "${value,,}" =~ ^(j|ja|y|yes)$ ]]
}

pauze() {
  echo -en "\n ${YW}▶${CL}  ${BO}$1${CL} " > /dev/tty
  read -r _ < /dev/tty
}

# clear faalt als TERM niet is gezet, en met set -e stopt het script dan
# nog voor de eerste controle. Een leeg scherm is nooit belangrijk genoeg
# om een installatie op te laten stranden.
clear 2>/dev/null || true
echo -e "
  ${BO}██╗  ██╗██╗      █████╗ ███╗   ██╗████████╗${CL}
  ${BO}██║ ██╔╝██║     ██╔══██╗████╗  ██║╚══██╔══╝${CL}
  ${BO}█████╔╝ ██║     ███████║██╔██╗ ██║   ██║   ${CL}
  ${BO}██╔═██╗ ██║     ██╔══██║██║╚██╗██║   ██║   ${CL}
  ${BO}██║  ██╗███████╗██║  ██║██║ ╚████║   ██║   ${CL}
  ${BO}╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝   ${CL}
        ${BO}P O R T A A L${CL}

        Proxmox LXC Installer v1.0
"

# ── Vereisten
[[ "$(id -u)" != "0" ]]      && msg_error "Draai dit script als root"
command -v pct   &>/dev/null || msg_error "pct niet gevonden. Is dit een Proxmox host?"
command -v pvesm &>/dev/null || msg_error "pvesm niet gevonden. Is dit een Proxmox host?"
command -v curl  &>/dev/null || msg_error "curl niet gevonden"
command -v ssh-keygen &>/dev/null || msg_error "ssh-keygen niet gevonden"

# Het adres van dit repo zelf. Dit is het enige dat concreet moet
# zijn, want hier komt de tweede helft van de installatie vandaan.
INSTALL_URL="https://raw.githubusercontent.com/damiaan111/klantportaal-installer/main/klantportaal/main/install/klantportaal-install.sh"

# ── Bestaat er al een klantportaal-container?
#
# Dit is geen nette-scriptbeleefdheid maar een vangnet. Draai je dit
# script per ongeluk twee keer, dan krijg je zonder deze controle een
# tweede container die naar dezelfde tunnel wijst, en dan zoek je een uur
# waarom je wisselend oude en nieuwe data ziet.
BESTAAND=$(pct list 2>/dev/null | awk 'NR>1 && $3 ~ /klantportaal/ {print $1" ("$3")"}' || true)
if [[ -n "$BESTAAND" ]]; then
  msg_warn "Er bestaat al een klantportaal-container:"
  echo -e "          ${BO}${BESTAAND}${CL}" >&2
  echo "" >&2
  echo -e "          Bijwerken doe je NIET met dit script, maar met:" >&2
  echo -e "            ${BO}pct enter <ID>${CL}  en daarin  ${BO}update${CL}" >&2
  echo "" >&2
  confirm "Toch een TWEEDE container maken?" || { echo -e "\n Geannuleerd."; exit 0; }
  echo ""
fi

# ── Template: nieuwste Debian, 13 als het kan en anders 12
pveam update >/dev/null 2>&1 || true
OS_TEMPLATE=""
for _serie in debian-13-standard_ debian-12-standard_; do
  OS_TEMPLATE=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' | grep "^${_serie}" | sort -V | tail -1)
  [[ -n "$OS_TEMPLATE" ]] && break
done
[[ -z "$OS_TEMPLATE" ]] && msg_error "Geen Debian-template gevonden. Controleer: pveam available --section system"
OS_NAAM=$([[ "$OS_TEMPLATE" == debian-13* ]] && echo "Debian 13" || echo "Debian 12")

# ── Storage detecteren
mapfile -t STORAGE_LIST < <(pvesm status 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
[[ ${#STORAGE_LIST[@]} -eq 0 ]] && msg_error "Geen actieve storage gevonden. Controleer: pvesm status"
DEF_STORAGE="${STORAGE_LIST[0]}"
for _s in "${STORAGE_LIST[@]}"; do
  [[ "$_s" == "local-lvm" ]] && DEF_STORAGE="local-lvm" && break
done

# ── Bridge detecteren
mapfile -t BRIDGE_LIST < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
[[ ${#BRIDGE_LIST[@]} -eq 0 ]] && BRIDGE_LIST=("vmbr0")
DEF_BRIDGE="${BRIDGE_LIST[0]}"

DEF_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

# ── Wizard: de container
echo -e " ${BO}Configureer de container${CL} ${DIM}(Enter voor de standaardwaarde)${CL}"
echo -e " ${DIM}$(printf '%0.s─' {1..56})${CL}\n"

CT_ID=$(ask       "Container ID"        "$DEF_CTID")
CT_HOSTNAME=$(ask "Hostname"            "klantportaal")

echo -e "         ${DIM}Beschikbare pools: ${STORAGE_LIST[*]}${CL}" >&2
STORAGE=$(ask     "Storage pool"        "$DEF_STORAGE")
_VALID=""
for _s in "${STORAGE_LIST[@]}"; do [[ "$_s" == "$STORAGE" ]] && _VALID=1 && break; done
[[ -z "$_VALID" ]] && msg_error "'${STORAGE}' is geen actieve storage pool. Kies uit: ${STORAGE_LIST[*]}"

# Postgres, de nachtelijke dumps EN de bijlagen die klanten uploaden.
# Dat laatste staat bewust in dezelfde container, maar het betekent wel
# dat de applicatie ruimte moet vrijhouden voor de database. Loopt het
# volume vol, dan kan Postgres zijn WAL niet meer wegschrijven en ligt
# het hele portaal plat. Zie src/platform/storage/ruimte.ts.
echo -e "         ${DIM}Hier komen ook de bijlagen van klanten op te staan,${CL}" >&2
echo -e "         ${DIM}dus dit getal is je opslaggrens. Ruim nemen is${CL}" >&2
echo -e "         ${DIM}makkelijker dan later vergroten.${CL}" >&2
DISK=$(ask        "Disk (GB)"           "40")
MEMORY=$(ask      "RAM (MB)"            "2048")
SWAP=$(ask        "Swap (MB)"           "512")
CORES=$(ask       "CPU cores"           "2")

echo -e "         ${DIM}Gevonden bridges : ${BRIDGE_LIST[*]}${CL}" >&2
BRIDGE=$(ask      "Netwerk bridge"      "$DEF_BRIDGE")

echo "" >&2
if confirm "Statisch IP instellen? (anders DHCP)"; then
  IP_CIDR=$(ask "IP + subnet (bijv. 192.168.1.50/24)" "")
  GATEWAY=$(ask "Gateway (bijv. 192.168.1.1)"         "")
  [[ -z "$IP_CIDR" || -z "$GATEWAY" ]] && msg_error "IP en gateway zijn verplicht bij een statisch IP"
  NET_CFG="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}"
  STATIC_IP="${IP_CIDR%%/*}"
else
  NET_CFG="name=eth0,bridge=${BRIDGE},ip=dhcp"
  STATIC_IP=""
fi

# ── Wizard: het portaal zelf
echo ""
echo -e " ${BO}Configureer het portaal${CL}"
echo -e " ${DIM}$(printf '%0.s─' {1..56})${CL}\n"

echo -e "         ${DIM}Het repo met de applicatiecode, als owner/naam. Mag een${CL}" >&2
echo -e "         ${DIM}private repo zijn: je zet straks een read-only deploy key.${CL}" >&2
REPO=$(ask "GitHub repo (owner/naam)" "")
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || msg_error "Verwacht de vorm owner/naam, bijvoorbeeld jansen/mijnportaal"
REPO_SSH="git@github.com:${REPO}.git"
DEPLOYKEY_URL="https://github.com/${REPO}/settings/keys/new"

echo "" >&2
echo -e "         ${DIM}Onder deze naam bereiken je klanten het portaal. Hij${CL}" >&2
echo -e "         ${DIM}bepaalt ook de links in de inlogmail, dus hij moet${CL}" >&2
echo -e "         ${DIM}kloppen met wat je in je tunnel instelt.${CL}" >&2
echo -e "         ${DIM}Bijvoorbeeld portal.voorbeeld.nl${CL}" >&2
PUBLIEKE_HOST=$(ask "Publieke hostname" "")
[[ -z "$PUBLIEKE_HOST" ]] && msg_error "Een publieke hostname is verplicht"

echo "" >&2
echo -e "         ${DIM}Het portaal luistert op poort 3000 zonder TLS. Alleen${CL}" >&2
echo -e "         ${DIM}je cloudflared-container mag daarbij. Vul zijn IP in,${CL}" >&2
echo -e "         ${DIM}dan zet ik een firewallregel die de rest weert.${CL}" >&2
echo -e "         ${DIM}Leeg laten betekent: heel je LAN mag erbij.${CL}" >&2
TUNNEL_IP=$(ask "IP van je cloudflared-container" "")

echo "" >&2
echo -e "         ${DIM}Adres waarvan klanten mail ontvangen en waarop zij${CL}" >&2
echo -e "         ${DIM}kunnen antwoorden. Bijvoorbeeld support@jouwdomein.nl${CL}" >&2
# Bewust geen standaardwaarde. Dit repo is publiek, en een mailadres in
# een publiek bestand wordt door spamcrawlers geoogst.
CONTACT_MAIL=$(ask "Support-adres" "")

echo "" >&2
echo -e "         ${DIM}Waar JIJ meldingen krijgt van nieuwe aanvragen. Leeg${CL}" >&2
echo -e "         ${DIM}laten gebruikt hetzelfde adres als hierboven.${CL}" >&2
STUDIO_MAIL=$(ask "Adres voor jouw eigen meldingen" "")
[[ -z "$STUDIO_MAIL" ]] && STUDIO_MAIL="$CONTACT_MAIL"

echo "" >&2
echo -e "         ${DIM}Grootste bestand dat een klant mag uploaden.${CL}" >&2
MAX_UPLOAD_MB=$(ask "Max per bestand (MB)" "2048")
[[ "$MAX_UPLOAD_MB" =~ ^[0-9]+$ && "$MAX_UPLOAD_MB" -gt 0 ]] \
  || msg_error "Verwacht een getal in megabytes, bijvoorbeeld 2048"

echo "" >&2
echo -e "         ${DIM}Opslag per klant. Later per klant te verruimen${CL}" >&2
echo -e "         ${DIM}zonder de applicatie aan te raken.${CL}" >&2
QUOTA_GB=$(ask "Opslag per klant (GB)" "5")
[[ "$QUOTA_GB" =~ ^[0-9]+$ && "$QUOTA_GB" -gt 0 ]] \
  || msg_error "Verwacht een getal in gigabytes, bijvoorbeeld 5"

# ── Overzicht
echo -e "\n ${BO}Overzicht${CL}\n ${DIM}$(printf '%0.s─' {1..56})${CL}"
msg_info "Container ID  : ${BO}${CT_ID}${CL}"
msg_info "Hostname      : ${BO}${CT_HOSTNAME}${CL}"
msg_info "OS            : ${BO}${OS_NAAM} (${OS_TEMPLATE})${CL}"
msg_info "Storage       : ${BO}${STORAGE}${CL}"
msg_info "Disk          : ${BO}${DISK} GB${CL}"
msg_info "RAM / Swap    : ${BO}${MEMORY} MB / ${SWAP} MB${CL}"
msg_info "CPU cores     : ${BO}${CORES}${CL}"
msg_info "Bridge        : ${BO}${BRIDGE}${CL}"
msg_info "IP            : ${BO}${STATIC_IP:-DHCP}${CL}"
msg_info "Repo          : ${BO}${REPO}${CL}"
msg_info "Publieke naam : ${BO}https://${PUBLIEKE_HOST}${CL}"
msg_info "Tunnel mag    : ${BO}${TUNNEL_IP:-heel het LAN}${CL}"
msg_info "Max upload    : ${BO}${MAX_UPLOAD_MB} MB per bestand${CL}"
msg_info "Per klant     : ${BO}${QUOTA_GB} GB opslag${CL}"
echo ""
confirm "Doorgaan met de installatie?" || { echo -e "\n Geannuleerd."; exit 0; }
echo ""

# ══════════════════════════════════════════════════════════════════════
#  Deploy key
# ══════════════════════════════════════════════════════════════════════
# De code staat in een PRIVATE repo, dus de container moet toegang
# krijgen. Een deploy key is hier het juiste gereedschap: hij geldt voor
# dit ene repo, alleen lezen, en je trekt hem met een klik in. Een
# persoonlijk token zou bij al je andere repos kunnen.
KEYDIR=$(mktemp -d)
trap 'rm -rf "$KEYDIR"' EXIT
ssh-keygen -t ed25519 -N "" -C "klantportaal-ct${CT_ID}" -f "${KEYDIR}/deploy_key" >/dev/null 2>&1
msg_ok "Deploy key aangemaakt (alleen deze container gebruikt hem)"

echo ""
echo -e " ${BO}Zet deze sleutel eenmalig op GitHub${CL}"
echo -e " ${DIM}$(printf '%0.s─' {1..56})${CL}"
echo ""
echo -e " ${BO}1.${CL} Open: ${BL}${DEPLOYKEY_URL}${CL}"
echo -e " ${BO}2.${CL} Title: ${BO}klantportaal-ct${CT_ID}${CL} (of wat je zelf wil)"
echo -e " ${BO}3.${CL} Laat ${BO}Allow write access${CL} UIT staan. Lezen is genoeg."
echo -e " ${BO}4.${CL} Plak deze regel in het veld Key:"
echo ""
echo -e "${GN}$(cat "${KEYDIR}/deploy_key.pub")${CL}"
echo ""
pauze "Klaar? Druk Enter om verder te gaan."

# ══════════════════════════════════════════════════════════════════════
#  Container
# ══════════════════════════════════════════════════════════════════════
TEMPLATE_PATH="/var/lib/vz/template/cache/${OS_TEMPLATE}"
if [[ ! -f "$TEMPLATE_PATH" ]]; then
  msg_info "${OS_NAAM} template downloaden (${OS_TEMPLATE})..."
  pveam download local "$OS_TEMPLATE" >/dev/null 2>&1 \
    || msg_error "Template download mislukt. Controleer: pveam available --section system"
  msg_ok "Template gedownload"
else
  msg_ok "Template al aanwezig: ${OS_TEMPLATE}"
fi

msg_info "LXC container aanmaken (ID ${CT_ID})..."
pct create "${CT_ID}" "local:vztmpl/${OS_TEMPLATE}" \
  --hostname     "${CT_HOSTNAME}" \
  --memory       "${MEMORY}" \
  --swap         "${SWAP}" \
  --rootfs       "${STORAGE}:${DISK}" \
  --cores        "${CORES}" \
  --net0         "${NET_CFG}" \
  --unprivileged 1 \
  --features     "nesting=1" \
  --start        1 \
  --onboot       1 \
  >/dev/null 2>&1
msg_ok "Container ${CT_ID} aangemaakt en gestart"

msg_info "Wachten op netwerk..."
FINAL_IP=""
for _i in {1..30}; do
  FINAL_IP=$(pct exec "${CT_ID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$FINAL_IP" ]] && break
  sleep 2
done
[[ -z "$FINAL_IP" && -n "$STATIC_IP" ]] && FINAL_IP="$STATIC_IP"
[[ -z "$FINAL_IP" ]] && msg_error "Container kreeg geen IP. Controleer bridge ${BRIDGE} en DHCP"
msg_ok "IP-adres: ${BO}${FINAL_IP}${CL}"

# Sleutel naar binnen, en meteen weer van de host af.
pct exec "${CT_ID}" -- mkdir -p /root/.ssh
pct push "${CT_ID}" "${KEYDIR}/deploy_key" /root/.ssh/klantportaal_deploy --perms 600 >/dev/null
msg_ok "Deploy key in de container geplaatst"

# ══════════════════════════════════════════════════════════════════════
#  Installeren
# ══════════════════════════════════════════════════════════════════════
msg_info "Klantportaal installeren. Dit duurt een paar minuten."
echo -e "         ${DIM}Node, Postgres 17 en de applicatie. Uitvoer hieronder.${CL}" >&2
echo ""

INSTALL_SCRIPT=$(curl -fsSL "$INSTALL_URL") \
  || msg_error "Kon het installatiescript niet ophalen: ${INSTALL_URL}"

pct exec "${CT_ID}" -- env \
  KP_REPO_SSH="${REPO_SSH}" \
  KP_PUBLIEKE_HOST="${PUBLIEKE_HOST}" \
  KP_TUNNEL_IP="${TUNNEL_IP}" \
  KP_CONTACT_MAIL="${CONTACT_MAIL}" \
  KP_MAIL_FROM="${CONTACT_MAIL}" \
  KP_MAIL_STUDIO="${STUDIO_MAIL}" \
  KP_MAX_UPLOAD_MB="${MAX_UPLOAD_MB}" \
  KP_QUOTA_GB="${QUOTA_GB}" \
  bash -c "${INSTALL_SCRIPT}" \
  || msg_error "De installatie in de container is mislukt. Zie de uitvoer hierboven."

ADMIN_TOKEN=$(pct exec "${CT_ID}" -- bash -c "grep '^ADMIN_TOKEN=' /opt/klantportaal/.env | cut -d= -f2-" 2>/dev/null || echo "")

# ══════════════════════════════════════════════════════════════════════
#  Klaar
# ══════════════════════════════════════════════════════════════════════
echo ""
echo -e " ${GN}${BO}Klantportaal is geinstalleerd.${CL}"
echo -e " ${DIM}$(printf '%0.s─' {1..56})${CL}"
echo ""
echo -e " ${YW}Container${CL}      CT ${BO}${CT_ID}${CL} op ${BO}${FINAL_IP}${CL}"
echo -e " ${YW}Studio-token${CL}   ${BO}${ADMIN_TOKEN:-zie /opt/klantportaal/.env}${CL}"
echo ""
echo -e " ${BO}Nog twee dingen te doen${CL}"
echo -e " ${DIM}$(printf '%0.s─' {1..56})${CL}"
echo ""
echo -e " ${BO}1.${CL} Zet dit in je bestaande cloudflared-tunnel:"
echo ""
echo -e "      Public hostname   ${GN}${PUBLIEKE_HOST}${CL}"
echo -e "      Service           ${GN}http://${FINAL_IP}:3000${CL}"
echo ""
echo -e " ${BO}2.${CL} Maak een klant aan om mee te testen:"
echo ""
echo -e "      ${BO}pct exec ${CT_ID} -- klantportaal-seed${CL}"
echo ""
echo -e " ${RD}${BO}Let op:${CL} inloggen werkt ALLEEN via https://${PUBLIEKE_HOST}."
echo -e " Op http://${FINAL_IP}:3000 blijft de inlogpagina terugkomen, want de"
echo -e " cookies van dit portaal eisen een beveiligde verbinding. Dat is"
echo -e " geen storing maar de beveiliging die zijn werk doet."
echo ""
echo -e " ${DIM}Bijwerken later:${CL}  ${BO}pct enter ${CT_ID}${CL}  en daarin  ${BO}update${CL}"
echo ""
echo -e " ${RD}${BO}Let op de back-up:${CL} de nachtelijke dump bevat de DATABASE,"
echo -e " niet de bijlagen. Neem CT ${CT_ID} mee in je Proxmox-back-up, anders"
echo -e " zijn de bestanden van je klanten weg bij een defecte container."
echo -e " ${DIM}Inloglinks zien:${CL}  ${BO}pct exec ${CT_ID} -- journalctl -u klantportaal -f${CL}"
echo ""
