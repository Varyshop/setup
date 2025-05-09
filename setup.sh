#!/bin/bash

# Kontrola zda skript již byl vykonán
SETUP_MARKER=".setup_complete"
if [ -f "$SETUP_MARKER" ]; then
    echo "Nastavení již bylo provedeno. Pokud chcete provést opětovné nastavení, smažte soubor $SETUP_MARKER"
    echo "Pro pokračování i přesto, že nastavení již bylo provedeno, použijte parametr --force"
    if [ "$1" != "--force" ]; then
        exit 0
    else
        echo "Parametr --force detekován, pokračuji s přenastavením..."
        shift # Odstranění parametru --force z argumentů
    fi
fi

# Kontrola, zda jsou zadány všechny potřebné parametry
if [ "$#" -lt 2 ]; then
    echo "Použití: $0 [--force] <domena> <email> [password]"
    echo "Příklad: $0 example.com info@example.com mojeheslo123"
    echo "         $0 --force example.com info@example.com noveheslo456"
    exit 1
fi

DOMAIN=$1
EMAIL=$2
PASSWORD=${3:-"$(openssl rand -base64 12)"}  # Použij třetí parametr nebo vygeneruj náhodné heslo

# Kontrola, zda je doména subdoménou
if [[ "$DOMAIN" == *"."*"."* ]]; then
    # Doména je již subdoménou, nebudeme přidávat www
    IS_SUBDOMAIN=true
    echo "Detekována subdoména: $DOMAIN. Nebude se přidávat www."
else
    IS_SUBDOMAIN=false
    echo "Detekována hlavní doména: $DOMAIN. Bude se přidávat www."
fi

# Kontrola existence Docker a Docker Compose
if ! [ -x "$(command -v docker)" ]; then
    echo "Chyba: Docker není nainstalován. Nainstalujte Docker a spusťte skript znovu." >&2
    exit 1
fi

if ! [ -x "$(command -v docker compose)" ] && ! [ -x "$(command -v docker-compose)" ]; then
    echo "Chyba: Docker Compose není nainstalován. Nainstalujte Docker Compose a spusťte skript znovu." >&2
    exit 1
fi

# Zjištění správného příkazu pro docker compose
if [ -x "$(command -v docker compose)" ]; then
    compose_command="docker compose"
else
    compose_command="docker-compose"
fi

echo "======================================================="
echo "Začínám nastavování prostředí pro doménu: $DOMAIN"
echo "Email pro Let's Encrypt: $EMAIL"
echo "Použitý příkaz Docker Compose: $compose_command"
echo "======================================================="

# Vytvoření .env souboru
echo "Vytvářím .env soubor..."
cat > .env << EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
POSTGRES_PASSWORD=$PASSWORD
EOF
if [ $? -ne 0 ]; then
    echo "Chyba: Nepodařilo se vytvořit soubor .env" >&2
    exit 1
fi
echo "✓ Soubor .env byl úspěšně vytvořen"

# Vytvoření adresářové struktury
echo "Vytvářím adresářovou strukturu..."
mkdir -p ./nginx/conf
if [ $? -ne 0 ]; then
    echo "Chyba: Nepodařilo se vytvořit adresář ./nginx/conf" >&2
    exit 1
fi

mkdir -p ./nginx/certbot/conf
if [ $? -ne 0 ]; then
    echo "Chyba: Nepodařilo se vytvořit adresář ./nginx/certbot/conf" >&2
    exit 1
fi

mkdir -p ./nginx/certbot/www
if [ $? -ne 0 ]; then
    echo "Chyba: Nepodařilo se vytvořit adresář ./nginx/certbot/www" >&2
    exit 1
fi

# Vytvoření potřebných souborů pro SSL, které bude nginx hledat
echo "Vytvářím potřebné SSL konfigurační soubory..."
# Vytvoření options-ssl-nginx.conf
cat > ./nginx/certbot/conf/options-ssl-nginx.conf << EOF
# Optimální SSL nastavení pro nginx
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
EOF

# Vytvoření ssl-dhparams.pem
echo "Generuji DH parametry pro lepší bezpečnost..."
openssl dhparam -out ./nginx/certbot/conf/ssl-dhparams.pem 2048
echo "✓ Adresářová struktura a SSL soubory byly úspěšně vytvořeny"

# Vytvoření adresářů pro data a konfigurace
echo "Vytvářím další potřebné adresáře..."
mkdir -p ./.config
if [ $? -ne 0 ]; then
    echo "Varování: Nepodařilo se vytvořit adresář ./.config (možná již existuje)"
fi

mkdir -p ./.data
if [ $? -ne 0 ]; then
    echo "Varování: Nepodařilo se vytvořit adresář ./.data (možná již existuje)"
fi

mkdir -p ./.db
if [ $? -ne 0 ]; then
    echo "Varování: Nepodařilo se vytvořit adresář ./.db (možná již existuje)"
fi
echo "✓ Další potřebné adresáře byly vytvořeny"

# Vytvoření konfigurace nginx z šablony
echo "Generuji počáteční konfiguraci nginx (pouze HTTP)..."

# Vytvoření dočasné konfigurace pouze s HTTP (pro získání certifikátu)
if [ "$IS_SUBDOMAIN" = true ]; then
    # Pro subdomény bez www
    cat > ./nginx/conf/app.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 503 "Server is setting up SSL certificates. Please try again in a few minutes.";
    }
}
EOF
else
    # Pro hlavní domény s www
    cat > ./nginx/conf/app.conf << EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 503 "Server is setting up SSL certificates. Please try again in a few minutes.";
    }
}
EOF
fi

# Vytvoření kompletní konfigurace pro pozdější použití
echo "Generuji kompletní konfiguraci nginx (HTTP+HTTPS) pro pozdější použití..."
mkdir -p ./templates
if [ "$IS_SUBDOMAIN" = true ]; then
    # Pro subdomény bez www
    cat > ./templates/full_config.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # SSL nastavení pro Nginx 
    ssl_session_cache shared:le_nginx_SSL:10m;
    ssl_session_timeout 1440m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://web:8069;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
else
    # Pro hlavní domény s www
    cat > ./templates/full_config.conf << EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN www.$DOMAIN;
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # SSL nastavení pro Nginx
    ssl_session_cache shared:le_nginx_SSL:10m;
    ssl_session_timeout 1440m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://web:8069;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
fi

if [ $? -ne 0 ]; then
    echo "Chyba: Nepodařilo se vytvořit konfigurační soubor Nginx" >&2
    exit 1
fi
echo "✓ Konfigurace Nginx byla úspěšně vytvořena"

# Vytvoření docker-compose.yml souboru
echo "Generuji docker-compose.yml..."
cat > docker-compose.yml << EOF
version: '3'

services:
  web:
    container_name: web
    image: varyshop/website:latest
    command: "python3 odoo-bin --addons-path=\"addons\" -r \${POSTGRES_USER-varyshop} -w \${POSTGRES_PASSWORD} --db_host db --db_port 5432"
    # command: "python3 odoo-bin --addons-path=\"addons,modules\" -r \${POSTGRES_USER-varyshop} -w \${POSTGRES_PASSWORD} --db_host db --db_port 5432"
    depends_on:
      - db
    volumes:
      # - ./modules:/app/modules
      - ./.config:/etc/odoo
      - ./.data:/root/.local/share/Odoo
    environment:
      HOST: db
      USER: \${POSTGRES_USER-varyshop}
      DB_NAME: \${POSTGRES_DB:-postgres}
      PASSWORD: \${POSTGRES_PASSWORD}
    networks:
      - proxy

  db:
    container_name: db
    image: postgres:15
    environment:
      POSTGRES_DB: \${POSTGRES_DB-postgres}
      POSTGRES_USER: \${POSTGRES_USER-varyshop}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - ./.db:/var/lib/postgresql/data
    ports:
      - \${POSTGRES_PORT:-5432}:5432
    networks:
      - proxy

  nginx:
    container_name: nginx
    image: nginx:alpine
    restart: unless-stopped
    depends_on:
      - web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf:/etc/nginx/conf.d
      - ./nginx/certbot/conf:/etc/letsencrypt
      - ./nginx/certbot/www:/var/www/certbot
    networks:
      - proxy
    command: "/bin/sh -c 'while :; do sleep 6h & wait \$\${!}; nginx -s reload; done & nginx -g \"daemon off;\"'"
    environment:
      - DOMAIN=\${DOMAIN}

  certbot:
    container_name: certbot
    image: certbot/certbot
    restart: unless-stopped
    volumes:
      - ./nginx/certbot/conf:/etc/letsencrypt
      - ./nginx/certbot/www:/var/www/certbot
    networks:
      - proxy
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait \$\${!}; done;'"
    environment:
      - DOMAIN=\${DOMAIN}
      - EMAIL=\${EMAIL}

networks:
  proxy:
    driver: bridge
EOF
if [ $? -ne 0 ]; then
    echo "Chyba: Nepodařilo se vytvořit soubor docker-compose.yml" >&2
    exit 1
fi
echo "✓ Soubor docker-compose.yml byl úspěšně vytvořen"

# Vytvoření init-letsencrypt skriptu
echo "Generuji inicializační skript pro Let's Encrypt..."
if [ "$IS_SUBDOMAIN" = true ]; then
    # Pro subdomény bez www
    cat > init-letsencrypt.sh << 'EOF'
#!/bin/bash

# Kontrola zda skript již byl vykonán
CERT_MARKER=".cert_complete"
if [ -f "$CERT_MARKER" ]; then
    echo "Certifikát již byl nastaven. Pokud chcete provést opětovné nastavení, smažte soubor $CERT_MARKER"
    echo "Pro pokračování i přesto, že certifikát již byl nastaven, použijte parametr --force"
    if [ "$1" != "--force" ]; then
        exit 0
    else
        echo "Parametr --force detekován, pokračuji s obnovením certifikátu..."
    fi
fi

if ! [ -x "$(command -v docker compose)" ] && ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Chyba: docker compose není nainstalován.' >&2
  exit 1
fi

# Zjištění správného příkazu pro docker compose
if [ -x "$(command -v docker compose)" ]; then
  compose_command="docker compose"
else
  compose_command="docker-compose"
fi

# Kontrola existence .env souboru
if [ ! -f ".env" ]; then
  echo "Chyba: Soubor .env neexistuje. Spusťte nejprve setup.sh" >&2
  exit 1
fi

# Načtení proměnných z .env
source .env
if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo "Chyba: DOMAIN nebo EMAIL nejsou nastaveny v .env souboru" >&2
  exit 1
fi

domains=($DOMAIN)
rsa_key_size=4096
data_path="./nginx/certbot"
email="$EMAIL" 

echo "======================================================="
echo "Začínám proces získání SSL certifikátu pro doménu: $DOMAIN"
echo "Email pro Let's Encrypt: $EMAIL"
echo "======================================================="

# Vytvoření adresářové struktury
echo "Kontroluji adresářovou strukturu..."
mkdir -p "$data_path/conf/live/$DOMAIN"
mkdir -p "$data_path/www"

# Vytvoření potřebných souborů pro SSL, které bude nginx hledat
echo "Vytvářím potřebné SSL konfigurační soubory..."
if [ ! -f "$data_path/conf/options-ssl-nginx.conf" ]; then
  # Vytvoření options-ssl-nginx.conf
  cat > "$data_path/conf/options-ssl-nginx.conf" << EOT
# Optimální SSL nastavení pro nginx
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
EOT
fi

# Vytvoření ssl-dhparams.pem pokud neexistuje
if [ ! -f "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "Generuji DH parametry..."
  openssl dhparam -out "$data_path/conf/ssl-dhparams.pem" 2048
fi
echo "✓ Adresářová struktura a SSL soubory připraveny"

echo "### Vytváření dummy certifikátu pro $domains ..."
path="/etc/letsencrypt/live/$DOMAIN"
mkdir -p "$data_path/conf/live/$DOMAIN"
$compose_command run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
if [ $? -ne 0 ]; then
  echo "Chyba: Nepodařilo se vytvořit dočasný certifikát" >&2
  exit 1
fi
echo "✓ Dočasný certifikát vytvořen"

echo "### Spouštění nginx ..."
$compose_command up --force-recreate -d nginx
if [ $? -ne 0 ]; then
  echo "Chyba: Nepodařilo se spustit nginx" >&2
  exit 1
fi
echo "✓ Nginx spuštěn"

# Počkáme, až se nginx nastartuje
echo "Čekám 5 sekund, než se nginx nastartuje..."
sleep 5

echo "### Smazání dummy certifikátu pro $domains ..."
$compose_command run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$DOMAIN && \
  rm -Rf /etc/letsencrypt/archive/$DOMAIN && \
  rm -Rf /etc/letsencrypt/renewal/$DOMAIN.conf" certbot
if [ $? -ne 0 ]; then
  echo "Varování: Nepodařilo se smazat dočasný certifikát (možná neexistuje)"
fi
echo "✓ Dočasný certifikát odstraněn"

echo "### Požádání o Let's Encrypt certifikát pro $domains ..."
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Pro testování použijte --staging
# --staging \
$compose_command run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $domain_args \
    --email $email \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot
if [ $? -ne 0 ]; then
  echo "Chyba: Nepodařilo se získat Let's Encrypt certifikát" >&2
  echo "Zkontrolujte, zda je doména $DOMAIN správně nastavena a směřuje na tento server" >&2
  exit 1
fi
echo "✓ Let's Encrypt certifikát úspěšně získán"

# Nahrazení dočasné konfigurace úplnou konfigurací
echo "### Aktualizuji konfiguraci Nginx s plnou podporou HTTPS..."
if [ -f "./templates/full_config.conf" ]; then
  cp "./templates/full_config.conf" "./nginx/conf/app.conf"
fi
echo "✓ Aktualizována konfigurace Nginx"

echo "### Restartuji nginx ..."
$compose_command exec nginx nginx -s reload
if [ $? -ne 0 ]; then
  echo "Chyba: Nepodařilo se restartovat nginx" >&2
  echo "Pokusíme se o alternativní restart..."
  $compose_command restart nginx
fi
echo "✓ Nginx restartován s novým certifikátem"

# Vytvoření značky úspěšného dokončení
touch "$CERT_MARKER"

echo "======================================================="
echo "Let's Encrypt certifikát byl úspěšně nastaven!"
echo "Nyní spusťte: $compose_command up -d"
echo "======================================================="
EOF
else
    # Pro hlavní domény s www
    cat > init-letsencrypt.sh << 'EOF'
#!/bin/bash

# Kontrola zda skript již byl vykonán
CERT_MARKER=".cert_complete"
if [ -f "\$CERT_MARKER" ]; then
    echo "Certifikát již byl nastaven. Pokud chcete provést opětovné nastavení, smažte soubor \$CERT_MARKER"
    echo "Pro pokračování i přesto, že certifikát již byl nastaven, použijte parametr --force"
    if [ "\$1" != "--force" ]; then
        exit 0
    else
        echo "Parametr --force detekován, pokračuji s obnovením certifikátu..."
    fi
fi

if ! [ -x "\$(command -v docker compose)" ] && ! [ -x "\$(command -v docker-compose)" ]; then
  echo 'Chyba: docker compose není nainstalován.' >&2
  exit 1
fi

# Zjištění správného příkazu pro docker compose
if [ -x "\$(command -v docker compose)" ]; then
  compose_command="docker compose"
else
  compose_command="docker-compose"
fi

# Kontrola existence .env souboru
if [ ! -f ".env" ]; then
  echo "Chyba: Soubor .env neexistuje. Spusťte nejprve setup.sh" >&2
  exit 1
fi

# Načtení proměnných z .env
source .env
if [ -z "\$DOMAIN" ] || [ -z "\$EMAIL" ]; then
  echo "Chyba: DOMAIN nebo EMAIL nejsou nastaveny v .env souboru" >&2
  exit 1
fi

domains=(\$DOMAIN www.\$DOMAIN)
rsa_key_size=4096
data_path="./nginx/certbot"
email="\$EMAIL" 

echo "======================================================="
echo "Začínám proces získání SSL certifikátu pro doménu: \$DOMAIN"
echo "Email pro Let's Encrypt: \$EMAIL"
echo "======================================================="

# Vytvoření adresářové struktury
echo "Kontroluji adresářovou strukturu..."
mkdir -p "\$data_path/conf/live/\$DOMAIN"
mkdir -p "\$data_path/www"
echo "✓ Adresářová struktura připravena"

echo "### Vytváření dummy certifikátu pro \$domains ..."
path="/etc/letsencrypt/live/\$DOMAIN"
mkdir -p "\$data_path/conf/live/\$DOMAIN"
\$compose_command run --rm --entrypoint "\\
  openssl req -x509 -nodes -newkey rsa:\$rsa_key_size -days 1\\
    -keyout '\$path/privkey.pem' \\
    -out '\$path/fullchain.pem' \\
    -subj '/CN=localhost'" certbot
if [ \$? -ne 0 ]; then
  echo "Chyba: Nepodařilo se vytvořit dočasný certifikát" >&2
  exit 1
fi
echo "✓ Dočasný certifikát vytvořen"

echo "### Spouštění nginx ..."
\$compose_command up --force-recreate -d nginx
if [ \$? -ne 0 ]; then
  echo "Chyba: Nepodařilo se spustit nginx" >&2
  exit 1
fi
echo "✓ Nginx spuštěn"

# Počkáme, až se nginx nastartuje
echo "Čekám 5 sekund, než se nginx nastartuje..."
sleep 5

echo "### Smazání dummy certifikátu pro \$domains ..."
\$compose_command run --rm --entrypoint "\\
  rm -Rf /etc/letsencrypt/live/\$DOMAIN && \\
  rm -Rf /etc/letsencrypt/archive/\$DOMAIN && \\
  rm -Rf /etc/letsencrypt/renewal/\$DOMAIN.conf" certbot
if [ \$? -ne 0 ]; then
  echo "Varování: Nepodařilo se smazat dočasný certifikát (možná neexistuje)"
fi
echo "✓ Dočasný certifikát odstraněn"

echo "### Požádání o Let's Encrypt certifikát pro \$domains ..."
domain_args=""
for domain in "\${domains[@]}"; do
  domain_args="\$domain_args -d \$domain"
done

# Pro testování použijte --staging
# --staging \\
\$compose_command run --rm --entrypoint "\\
  certbot certonly --webroot -w /var/www/certbot \\
    \$domain_args \\
    --email \$email \\
    --rsa-key-size \$rsa_key_size \\
    --agree-tos \\
    --force-renewal" certbot
if [ \$? -ne 0 ]; then
  echo "Chyba: Nepodařilo se získat Let's Encrypt certifikát" >&2
  echo "Zkontrolujte, zda je doména \$DOMAIN správně nastavena a směřuje na tento server" >&2
  exit 1
fi
echo "✓ Let's Encrypt certifikát úspěšně získán"

echo "### Restartuji nginx ..."
\$compose_command exec nginx nginx -s reload
if [ \$? -ne 0 ]; then
  echo "Chyba: Nepodařilo se restartovat nginx" >&2
  exit 1
fi
echo "✓ Nginx restartován s novým certifikátem"

# Vytvoření značky úspěšného dokončení
touch "\$CERT_MARKER"

echo "======================================================="
echo "Let's Encrypt certifikát byl úspěšně nastaven!"
echo "Nyní spusťte: \$compose_command up -d"
echo "======================================================="
EOF
fi

# Nastavení práv pro spuštění
chmod +x init-letsencrypt.sh
if [ $? -ne 0 ]; then
    echo "Varování: Nepodařilo se nastavit práva pro spuštění skriptu init-letsencrypt.sh"
fi
echo "✓ Inicializační skript pro Let's Encrypt byl úspěšně vytvořen a nastaven jako spustitelný"

# Vytvoření značky úspěšného dokončení
touch "$SETUP_MARKER"

# Spuštění init-letsencrypt.sh
echo "Spouštím init-letsencrypt.sh..."
./init-letsencrypt.sh
if [ $? -ne 0 ]; then
    echo "Varování: Skript init-letsencrypt.sh skončil s chybou"
fi

# Výpis informací
echo "======================================================="
echo "Konfigurace byla úspěšně vytvořena!"
echo "Doména: $DOMAIN"
echo "Email: $EMAIL"
echo "Databázové heslo: $PASSWORD"
echo "======================================================="
echo "Nastavení Let's Encrypt bylo dokončeno, nyní spusťte:"
echo "$compose_command up -d"
echo "======================================================="