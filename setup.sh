#!/bin/bash

# ============================================================
# Скрипт автоматической установки:
# WordPress (маскировка) + 3x-ui + VLESS Reality Self-steal
# Домен: crossx.noip.pl (захардкожен)
# ОС: Ubuntu 20.04 / 22.04 / 24.04
# ВЕРСИЯ: 1.2 (фиксированный домен, без авто-создания inbound)
# ============================================================

set -e

# Ваш домен (измените здесь, если нужно)
DOMAIN="crossx.noip.pl"
VPN_DOMAIN="$DOMAIN"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# Проверка прав и системы
# ============================================================

if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт должен запускаться от имени root (или через sudo)"
    exit 1
fi

if ! grep -q "Ubuntu" /etc/os-release; then
    print_error "Этот скрипт работает только на Ubuntu 20.04/22.04/24.04"
    exit 1
fi

TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
if [[ $TOTAL_MEM -lt 1800 ]]; then
    print_warning "У вас меньше 2 ГБ RAM. WordPress + 3x-ui могут работать медленно."
    read -p "Продолжить? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

print_info "Домен для установки: $DOMAIN"

# ============================================================
# Сбор параметров от пользователя
# ============================================================

echo ""
echo "=========================================="
echo "Настройка VPN + WordPress"
echo "Домен: $DOMAIN"
echo "=========================================="
echo ""

read -p "Введите email для SSL-сертификата [admin@$DOMAIN]: " EMAIL
if [[ -z "$EMAIL" ]]; then
    EMAIL="admin@$DOMAIN"
fi

read -sp "Введите пароль администратора WordPress (мин. 12 символов): " WP_ADMIN_PASS
echo ""
if [[ ${#WP_ADMIN_PASS} -lt 12 ]]; then
    print_error "Пароль должен содержать минимум 12 символов"
    exit 1
fi

print_info "Email: $EMAIL"
print_info "Пароль: ********"
echo ""

# ============================================================
# Проверка DNS
# ============================================================

print_info "Проверка DNS для $DOMAIN..."
DNS_IP=$(dig +short $DOMAIN A 2>/dev/null | head -n1 || true)
SERVER_IP=$(curl -s https://api.ipify.org)

if [[ -z "$DNS_IP" ]]; then
    print_warning "DNS для $DOMAIN не найден или не успел обновиться."
    print_warning "Текущий IP сервера: $SERVER_IP"
    print_warning "Если DNS еще не обновился, SSL может не получиться."
    read -p "Продолжить? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
elif [[ "$DNS_IP" != "$SERVER_IP" ]]; then
    print_warning "DNS указывает на $DNS_IP, но IP этого сервера: $SERVER_IP"
    print_warning "SSL-сертификат может не получитьcя."
    read -p "Продолжить? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    print_success "DNS корректно указывает на $SERVER_IP"
fi

# ============================================================
# Генерация случайных значений для безопасности
# ============================================================

print_info "Генерация случайных значений..."

PANEL_PATH=$(openssl rand -hex 8)
PANEL_PORT=54321
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS=$(openssl rand -base64 18)
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)

print_info "Генерация Reality ключей через x25519..."
# Устанавливаем xray для генерации ключей
curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh | bash > /dev/null 2>&1 || true

XRAY_KEYS=$(/usr/local/xray/xray x25519)
REALITY_PRIVATE_KEY=$(echo "$XRAY_KEYS" | grep "Private key:" | awk '{print $3}')
REALITY_PUBLIC_KEY=$(echo "$XRAY_KEYS" | grep "Public key:" | awk '{print $3}')

print_success "Все значения сгенерированы"

# ============================================================
# Обновление системы
# ============================================================

print_info "Обновление системы (это может занять несколько минут)..."
apt update -y
apt upgrade -y
print_success "Система обновлена"

# ============================================================
# Установка зависимостей
# ============================================================

print_info "Установка Nginx, PHP, MariaDB, Certbot..."
apt install -y nginx mariadb-server php-fpm php-mysql php-gd php-mbstring php-xml php-curl php-zip unzip wget curl git dnsutils apache2-utils

PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"

print_success "Зависимости установлены (PHP $PHP_VERSION)"

# ============================================================
# Настройка MariaDB
# ============================================================

print_info "Настройка базы данных..."
systemctl enable mariadb
systemctl start mariadb

mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

print_success "База данных создана"

# ============================================================
# Установка WordPress
# ============================================================

print_info "Скачивание и установка WordPress..."

rm -f /etc/nginx/sites-enabled/default

cd /tmp
rm -rf wordpress latest-ru_RU.tar.gz
wget -q https://ru.wordpress.org/latest-ru_RU.tar.gz
tar -xzf latest-ru_RU.tar.gz

rm -rf /var/www/$DOMAIN
mv wordpress /var/www/$DOMAIN

cd /var/www/$DOMAIN
cp wp-config-sample.php wp-config.php

sed -i "s/database_name_here/$DB_NAME/" wp-config.php
sed -i "s/username_here/$DB_USER/" wp-config.php
sed -i "s/password_here/$DB_PASS/" wp-config.php

SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
perl -i -pe '
    BEGIN { $salt = shift; }
    if (/define\(.*AUTH_KEY.*\)/) { $_ = $salt . "\n"; }
    elsif (/define\(.*(SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT).*\)/) { $_ = ""; }
' -- "$SALT" wp-config.php

chown -R www-data:www-data /var/www/$DOMAIN
find /var/www/$DOMAIN -type d -exec chmod 755 {} \;
find /var/www/$DOMAIN -type f -exec chmod 644 {} \;

# Установка WP-CLI
print_info "Установка WP-CLI..."
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

print_success "WordPress установлен"

# ============================================================
# Получение SSL-сертификатов
# ============================================================

print_info "Получение SSL-сертификатов от Let's Encrypt..."

apt install -y certbot

# Временный конфиг Nginx для HTTP
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# Получаем сертификат
if ! certbot certonly --webroot -w /var/www/$DOMAIN -d $DOMAIN --non-interactive --agree-tos -m $EMAIL; then
    print_error "Не удалось получить SSL-сертификат. Возможные причины:"
    print_error "1. DNS еще не обновился (noip.pl может обновляться до 10 минут)"
    print_error "2. Лимит Let's Encrypt на домен noip.pl исчерпан"
    print_error "3. Домен не указывает на этот IP"
    exit 1
fi

print_success "SSL-сертификаты получены"

# ============================================================
# Финальная настройка Nginx с SSL
# ============================================================

print_info "Настройка Nginx с SSL..."

cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }
    
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    
    root /var/www/$DOMAIN;
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
    }
    
    # Скрытая панель 3x-ui
    location /$PANEL_PATH/ {
        proxy_pass http://127.0.0.1:$PANEL_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Защита админки WordPress
    location = /wp-login.php {
        auth_basic "Admin Area";
        auth_basic_user_file /etc/nginx/.htpasswd;
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    # Блокировка чувствительных файлов
    location ~ /\.ht {
        deny all;
    }
    
    location ~ /wp-config.php {
        deny all;
    }
    
    location ~ /\.git {
        deny all;
    }
    
    # Кэширование статики
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

htpasswd -bc /etc/nginx/.htpasswd admin "$WP_ADMIN_PASS"

nginx -t
systemctl restart nginx

print_success "Nginx настроен"

# ============================================================
# Установка 3x-ui (БЕЗ автоматического создания Inbound)
# ============================================================

print_info "Установка 3x-ui..."

if systemctl is-active --quiet x-ui; then
    systemctl stop x-ui
fi

# Автоматическая установка с параметрами
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
1
y
$PANEL_PORT
/$PANEL_PATH/
EOF

# Настраиваем 3x-ui на локальный порт
cd /usr/local/x-ui
cat > config.json <<EOF
{
    "listen": "127.0.0.1",
    "port": $PANEL_PORT,
    "basePath": "/$PANEL_PATH/",
    "certFile": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
    "keyFile": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
}
EOF

systemctl restart x-ui
systemctl enable x-ui

print_success "3x-ui установлен"

# ============================================================
# Настройка WordPress через WP-CLI
# ============================================================

print_info "Настройка WordPress..."

cd /var/www/$DOMAIN

# Завершаем установку WordPress
wp core install --url="https://$DOMAIN" --title="Мой Блог" --admin_user="admin" --admin_password="$WP_ADMIN_PASS" --admin_email="$EMAIL" --allow-root --skip-email

# Устанавливаем тему и плагины
wp theme install astra --activate --allow-root 2>/dev/null || print_warning "Тема Astra не установилась"
wp plugin install wordfence --activate --allow-root 2>/dev/null || true
wp plugin install updraftplus --activate --allow-root 2>/dev/null || true

# Создаем страницы
wp post create --post_type=page --post_title="О нас" --post_content="<p>Добро пожаловать на наш сайт! Мы пишем о путешествиях, технологиях и жизни.</p>" --post_status=publish --allow-root
wp post create --post_type=page --post_title="Контакты" --post_content="<p>Свяжитесь с нами через форму обратной связи.</p>" --post_status=publish --allow-root

# Создаем статьи
wp post create --post_type=post --post_title="Топ-10 мест для путешествий в 2026 году" --post_content="<p>В этой статье мы расскажем о лучших местах для отдыха. От пляжей Таиланда до горных курортов Швейцарии.</p>" --post_status=publish --allow-root
wp post create --post_type=post --post_title="Как настроить домашний сервер" --post_content="<p>Подробное руководство по настройке домашнего сервера. От выбора железа до установки софта.</p>" --post_status=publish --allow-root
wp post create --post_type=post --post_title="Обзор лучших VPN-протоколов" --post_content="<p>Сравниваем современные протоколы: VLESS, Reality, WireGuard, Amnezia. Плюсы и минусы каждого.</p>" --post_status=publish --allow-root

# Настраиваем permalink
wp rewrite structure '/%postname%/' --allow-root

print_success "WordPress настроен"

# ============================================================
# Безопасность и cron
# ============================================================

print_info "Настройка безопасности..."

cat >> /var/www/$DOMAIN/wp-config.php <<'EOF'

add_filter('xmlrpc_enabled', '__return_false');
define('DISALLOW_FILE_EDIT', true);
define('WP_POST_REVISIONS', 3);
EOF

apt install -y ufw
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Автообновление SSL-сертификатов
cat > /etc/cron.d/certbot-renew <<EOF
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF

print_success "Безопасность настроена"

# ============================================================
# Очистка и финальная информация
# ============================================================

rm -rf /tmp/wordpress /tmp/latest-ru_RU.tar.gz

echo ""
echo "=========================================="
echo -e "${GREEN}Установка завершена успешно!${NC}"
echo "=========================================="
echo ""
echo -e "${BLUE}📋 Данные для подключения:${NC}"
echo ""
echo "🌐 Ваш сайт:      https://$DOMAIN"
echo "🔐 Админка:       https://$DOMAIN/wp-login.php"
echo "   Логин:         admin"
echo "   Пароль:        $WP_ADMIN_PASS"
echo ""
echo -e "${BLUE}🔧 Панель 3x-ui:${NC}"
echo "   URL:           https://$DOMAIN/$PANEL_PATH/"
echo "   Логин:         admin"
echo "   Пароль:        admin (СМЕНИТЕ НЕМЕДЛЕННО!)"
echo ""
echo -e "${BLUE}🚀 Данные для Inbound (создайте вручную в панели 3x-ui):${NC}"
echo "   Protocol:      VLESS"
echo "   Port:          443"
echo "   Network:       tcp"
echo "   Security:      reality"
echo "   UUID:          $VLESS_UUID"
echo "   Flow:          xtls-rprx-vision"
echo "   Fingerprint:   chrome"
echo "   SNI:           $DOMAIN"
echo "   Public Key:    $REALITY_PUBLIC_KEY"
echo "   Private Key:   $REALITY_PRIVATE_KEY"
echo "   Fallback:      $PHP_SOCK"
echo ""
echo -e "${YELLOW}⚠️  Что делать дальше:${NC}"
echo "1. Откройте https://$DOMAIN — должен работать WordPress"
echo "2. Войдите в панель: https://$DOMAIN/$PANEL_PATH/"
echo "3. Смените пароль admin/admin в настройках панели"
echo "4. Создайте Inbound вручную с параметрами выше"
echo "5. Настройте клиент (v2rayN, Shadowrocket, Happ)"
echo ""
echo -e "${GREEN}Готово!${NC}"
echo ""

# Сохраняем все данные в файл
cat > /root/vpn-setup-info.txt <<EOF
Данные установки: $(date)
Домен: $DOMAIN
Email: $EMAIL

WordPress:
  URL: https://$DOMAIN
  Admin: https://$DOMAIN/wp-login.php
  Login: admin
  Password: $WP_ADMIN_PASS

3x-ui Panel:
  URL: https://$DOMAIN/$PANEL_PATH/
  Port: $PANEL_PORT
  Login: admin
  Password: admin (СМЕНИТЕ!)

VPN (VLESS Reality) - данные для ручного создания Inbound:
  Protocol: VLESS
  Port: 443
  Network: tcp
  Security: reality
  UUID: $VLESS_UUID
  Flow: xtls-rprx-vision
  Fingerprint: chrome
  SNI (Server Names): $DOMAIN
  Public Key: $REALITY_PUBLIC_KEY
  Private Key: $REALITY_PRIVATE_KEY
  Fallback (Dest): $PHP_SOCK

VLESS URL (для импорта в клиент):
  vless://$VLESS_UUID@$DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN&fp=chrome&type=tcp#RealityVPN-$DOMAIN
EOF

chmod 600 /root/vpn-setup-info.txt
print_info "Все данные сохранены в /root/vpn-setup-info.txt"
