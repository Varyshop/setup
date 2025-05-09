# Automatizované nasazení Varyshop s Nginx a Let's Encrypt

Tento repozitář obsahuje konfigurační soubory pro nasazení Varyshop aplikace s Nginx a automatickým SSL certifikátem pomocí Let's Encrypt.

## Požadavky

- Docker a Docker Compose nainstalované na vašem serveru
- Veřejně dostupná IP adresa
- Registrovaná doména s A záznamem směřujícím na váš server
- Otevřené porty 80 a 443 na firewallu

```bash
chmod +x setup.sh
```
## Rychlé nasazení

Pro rychlé nastavení použijte následující příkaz:

```bash
./setup.sh vase-domena.cz vas-email@example.com [volitelne-heslo]
```

Příklad:
```bash
./setup.sh example.com admin@example.com silneheslo123
```

Pro opětovné nastavení:
```bash
./setup.sh --force vase-domena.cz vas-email@example.com
```

## Postup nasazení

1. Spusťte setup skript:
   ```bash
   ./setup.sh vase-domena.cz vas-email@example.com
   ```

2. Získejte SSL certifikát:
   ```bash
   ./init-letsencrypt.sh
   ```

3. Spusťte všechny kontejnery:
   ```bash
   docker compose up -d
   ```

## Struktura projektu

- `docker-compose.yml` - Hlavní konfigurační soubor pro Docker
- `setup.sh` - Skript pro automatické nastavení
- `init-letsencrypt.sh` - Skript pro inicializaci SSL certifikátu
- `.env` - Soubor s proměnnými prostředí
- `nginx/conf/` - Adresář s konfigurací Nginx
- `nginx/certbot/` - Adresář pro Let's Encrypt certifikáty

## Automatická obnova certifikátu

Certifikát se automaticky obnovuje každých 12 hodin (pokud je to potřeba). Nginx se automaticky restartuje po obnovení certifikátu.
