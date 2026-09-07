# Klantportaal, Proxmox LXC installer

Installatiescripts die een klantportaal in een LXC-container op Proxmox
zetten: Node 22, PostgreSQL 17, de applicatie en een systemd-service.

Dit repo bevat alleen installatielogica. Het vraagt tijdens de installatie
naar het repo met de applicatiecode en naar de hostname, zodat hier niets
staat over wie het gebruikt of waarvoor. De applicatiecode kan in een
private repo staan en wordt met een read-only deploy key opgehaald.

## Installeren

Open de shell op je **Proxmox host** (als root) en plak dit:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/damiaan111/klantportaal-installer/main/klantportaal/main/ct/klantportaal.sh)"
```

Het script vraagt om je containerinstellingen, om het repo met de
applicatie en om de publieke hostname. Daarna maakt het een deploy key aan
die je eenmalig op GitHub zet, en installeert het de rest. Reken op vijf
tot tien minuten.

**Wat je nodig hebt:** Proxmox VE 7 of hoger, root toegang, een bridge met
internet, en iets dat HTTPS afhandelt voor de container. Bijvoorbeeld een
cloudflared-tunnel of een reverse proxy met een geldig certificaat.

## Waarschuwing over HTTPS, lees dit voordat je gaat testen

Het portaal werkt **alleen** achter HTTPS. Alle cookies hebben de
`__Host-`prefix, en een browser weigert die op te slaan op een verbinding
die geen beveiligde context is. `http://192.168.1.50:3000` is dat niet,
`localhost` wel.

Dus: op het LAN-adres van de container krijg je een inlogpagina die blijft
terugkomen, zonder foutmelding. Dat is geen storing maar de beveiliging
die doet wat hij moet doen. Ga via je eigen hostname over HTTPS naar
binnen, en dan werkt het.

## Na de installatie

Het script eindigt met wat je nog moet doen. Kort:

**1. Hostname naar de container laten wijzen**

| Veld | Waarde |
|---|---|
| Public hostname | de hostname die je hebt ingevuld |
| Service | `http://<ip-van-de-container>:3000` |

Heb je bij de installatie het IP van je tunnelcontainer ingevuld, dan
staat er een firewallregel die poort 3000 alleen vanaf dat IP toelaat.
Anders mag heel je LAN erbij, en dan is `/studio` bereikbaar voor elk
apparaat in je netwerk.

**2. Demodata om mee te testen**

```bash
pct exec <CT_ID> -- klantportaal-seed
```

**3. Inloggen als klant**

Zolang er geen SMTP is, staan de inloglinks in het journaal:

```bash
pct exec <CT_ID> -- journalctl -u klantportaal -f
```

Vraag een link aan op `/inloggen` en hij verschijnt in dat venster.

**4. Inloggen als studio**

Het studio-token staat aan het eind van de installatie op je scherm, en in
`/opt/klantportaal/.env`. Daarmee kom je op `/studio`.

## Bijwerken

```bash
pct enter <CT_ID>
update
```

Dat is bewust een ander commando dan de installatie. Onder dit portaal zit
een database met klantdata, en een installatiescript dat ook kan updaten
is een installatiescript dat je database kan wissen. Draai je het
`curl`-commando opnieuw, dan waarschuwt het dat er al een container is en
wijst het je hierheen.

Wat `update` doet, in deze volgorde:

1. Stoppen als er lokale wijzigingen in de code staan
2. `pg_dump` naar `/var/backups/klantportaal`, en pas daarna verder
3. `git fetch` en vooruitspoelen naar `origin/main`
4. `npm ci`
5. `npm run migrate`
6. Service herstarten en controleren dat hij ook echt opkomt

Gaan de migraties mis, dan stopt hij en noemt hij het commando waarmee je
de dump terugzet. Ben je al bij, dan doet hij niets en gooit hij de dump
weer weg.

## Back-ups

Elke nacht om 03:30 een `pg_dump` naar `/var/backups/klantportaal`, zeven
nachten bewaard. Dat is bedoeld tegen een misgelopen migratie of een
verkeerde handeling, niet tegen brand. Neem dat pad mee in je
Proxmox-back-up als je het echt wil bewaren.

## Wat er in de container komt

| Onderdeel | Keuze | Waarom |
|---|---|---|
| Debian | 13 als het template er is, anders 12 | Beide werken, het script kijkt wat beschikbaar is |
| Node | 22 via NodeSource | De applicatie eist minstens 22 |
| PostgreSQL | 17 via PGDG | Debian 12 levert 15, en dit moet op beide gelijk uitpakken |
| Collatie | ICU `nl-NL` | Taalkundig correcte sortering, gelijk op elk platform. **Later niet te wijzigen zonder dump-en-restore**, dus het script controleert het na het aanmaken |
| Gebruiker | `klantportaal`, geen root | De service heeft geen rootrechten nodig |
| Bind-adres | `HOST=0.0.0.0` plus firewallregel | De tunnel is meestal een aparte container en moet erbij kunnen. De applicatie luistert standaard alleen op loopback, dus dit is een bewuste keuze die zichtbaar in `.env` staat |
| Tijdzone | Europe/Amsterdam | De applicatie toont tijden in die zone, en een container op UTC maakt het opzoeken van een fout onnodig lastig |

## Als iets niet werkt

```bash
# Draait de service?
pct exec <CT_ID> -- systemctl status klantportaal

# Wat zegt hij?
pct exec <CT_ID> -- journalctl -u klantportaal -n 50

# Is de database gezond en met de juiste collatie?
pct exec <CT_ID> -- su - postgres -c "psql -c '\l portaal'"

# Werkt het portaal binnen de container zelf?
pct exec <CT_ID> -- curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/gezondheid
```

Die laatste hoort `200` te geven. Krijg je dat wel maar in je browser
niets, dan zit het probleem in de tunnel of de firewallregel en niet in de
applicatie.

## Nagelopen op

De OS-stappen zijn getest op een verse Debian 12: Node v22.23.2,
PostgreSQL 17.11 uit PGDG, een database met `datlocprovider = i`, en een
sortering die gelijk is aan de ontwikkelomgeving. Beide scripts zijn ook
uitgevoerd op een machine zonder Proxmox, om te zien dat ze dan netjes
stoppen met een uitleg in plaats van met een syntaxfout.

`.gitattributes` dwingt LF af. De scripts waren eerst met CRLF geschreven,
en bash struikelt daarover met `set: pipefail: invalid option name`. Dat
zegt niets over de oorzaak, en de installatie zou bij de eerste regel zijn
gestopt. Deze bestanden gaan rechtstreeks van `curl` naar `bash`, dus wat
hier in git staat is precies wat er wordt uitgevoerd.

## Indeling

```
klantportaal/main/
├── ct/klantportaal.sh                 Draai dit op je Proxmox host
└── install/klantportaal-install.sh    Installatielogica in de container
```

Deze indeling volgt de conventie van de Proxmox community-scripts, maar
zonder afhankelijkheid van hun build.func. Beide scripts zijn
zelfstandig.
