#!/bin/bash

# ============================================================
# Скрипт автоматической установки:
# WordPress (маскировка) + 3x-ui + VLESS Reality Self-steal
# ОС: Ubuntu 20.04 / 22.04 / 24.04
# ============================================================

set -e  # Останавливать при ошибках

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция вывода
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

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

print_info "Проверка системы завершена"

# ============================================================
# Сбор параметров от пользователя
# ============================================================

echo ""
echo "=========================================="
echo "Настройка VPN + WordPress"
echo "=========================================="
echo ""

# Домен
read -p "Введите ваш домен (например, mysite.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    print_error "Домен не может быть пустым"
    exit 1
fi

# Email для SSL
read -p "Введите email для SSL-сертификата (например, admin@$DOMAIN): " EMAIL
if [[ -z "$EMAIL" ]]; then
    EMAIL="admin@$DOMAIN"
fi

# Пароль администратора WordPress
read -sp "Введите пароль администратора WordPress (мин. 12 символов): " WP_ADMIN_PASS
echo ""
if [[ ${#WP_ADMIN_PASS} -lt 12 ]]; then
    print_error "Пароль должен содержать минимум 12 символов"
    exit 1
fi

# Поддомен для VPN (опционально)
read -p "Введите поддомен для VPN (например, vpn.$DOMAIN) [Enter для $DOMAIN]: " VPN_DOMAIN
if [[ -z "$VPN_DOMAIN" ]]; then
    VPN_DOMAIN="$DOMAIN"
fi

print_info "Домен: $DOMAIN"
print_info "Email: $EMAIL"
print_info "VPN домен: $VPN_DOMAIN"
print_info "Пароль: ********"
echo ""

# ============================================================
# Генерация случайных значений для безопасности
# ============================================================

print_info "Генерация случайных значений..."

# Случайный путь для панели 3x-ui
PANEL_PATH=$(openssl rand -hex 8)
PANEL_PORT=54321

# Случайный путь для VPN
VPN_PATH=$(openssl rand -hex 6)

# Пароль базы данных
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS=$(openssl rand -base64 18)

# UUID для VLESS
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)

# Reality ключи
REALITY_PRIVATE_KEY=$(openssl rand -base64 32 | tr -d '=+/' | head -c 43)
REALITY_PUBLIC_KEY=$(openssl rand -base64 32 | tr -d '=+/' | head -c 43)

print_success "Случайные значения сгенерированы"

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
apt install -y nginx mariadb-server php-fpm php-mysql php-gd php-mbstring php-xml php-curl php-zip unzip wget curl git

# Определяем версию PHP
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

# Удаляем стандартную страницу Nginx
rm -f /etc/nginx/sites-enabled/default

# Скачиваем WordPress
cd /tmp
rm -rf wordpress latest-ru_RU.tar.gz
wget -q https://ru.wordpress.org/latest-ru_RU.tar.gz
tar -xzf latest-ru_RU.tar.gz

# Перемещаем в директорию сайта
rm -rf /var/www/$DOMAIN
mv wordpress /var/www/$DOMAIN

# Настраиваем wp-config.php
cd /var/www/$DOMAIN
cp wp-config-sample.php wp-config.php

# Настраиваем базу данных
sed -i "s/database_name_here/$DB_NAME/" wp-config.php
sed -i "s/username_here/$DB_USER/" wp-config.php
sed -i "s/password_here/$DB_PASS/" wp-config.php

# Генерируем security keys
SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
perl -i -pe '
    BEGIN { $salt = shift; }
    if (/define\(.*AUTH_KEY.*\)/) { $_ = $salt . "\n"; }
    elsif (/define\(.*(SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT).*\)/) { $_ = ""; }
' -- "$SALT" wp-config.php

# Устанавливаем права
chown -R www-data:www-data /var/www/$DOMAIN
find /var/www/$DOMAIN -type d -exec chmod 755 {} \;
find /var/www/$DOMAIN -type f -exec chmod 644 {} \;

print_success "WordPress установлен"

# ============================================================
# Установка и настройка Nginx
# ============================================================

print_info "Настройка Nginx..."

cat > /etc/nginx/sites-available/$DOMAIN <<EOF
# WordPress + Self-steal VPN
# Домен: $DOMAIN

server {
    listen 80;
    server_name $DOMAIN;
    
    # Редирект на HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
    
    # Для certbot
    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    # SSL сертификаты
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    
    # Корневая директория WordPress
    root /var/www/$DOMAIN;
    index index.php index.html index.htm;
    
    # WordPress (fallback для Reality)
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    # PHP обработка
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
    }
    
    # Скрытая панель 3x-ui (только через длинный случайный путь)
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
    
    # Блокировка доступа к чувствительным файлам
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

# Создаем файл пароля для админки
apt install -y apache2-utils
htpasswd -bc /etc/nginx/.htpasswd admin "$WP_ADMIN_PASS"

# Активируем сайт
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

# Проверяем конфиг
nginx -t
systemctl restart nginx

print_success "Nginx настроен"

# ============================================================
# Установка 3x-ui
# ============================================================

print_info "Установка 3x-ui..."

# Останавливаем стандартный порт (будем использовать свой)
if systemctl is-active --quiet x-ui; then
    systemctl stop x-ui
fi

# Устанавливаем 3x-ui
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
1
y
$PANEL_PORT
$PANEL_PATH
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

print_success "3x-ui установлен"

# ============================================================
# Генерация SSL-сертификатов
# ============================================================

print_info "Получение SSL-сертификатов от Let's Encrypt..."

apt install -y certbot python3-certbot-nginx

# Останавливаем nginx временно для standalone режима
systemctl stop nginx

# Получаем сертификат
certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m $EMAIL

# Запускаем nginx
systemctl start nginx

print_success "SSL-сертификаты получены"

# ============================================================
# Генерация правдоподобного контента для WordPress
# ============================================================

print_info "Создание правдоподобного контента..."

# Создаем статьи в базе данных напрямую
mysql $DB_NAME <<EOF
-- Создаем администратора
INSERT INTO wp_users (user_login, user_pass, user_nicename, user_email, user_url, user_registered, display_name)
VALUES ('admin', MD5('$WP_ADMIN_PASS'), 'Администратор', '$EMAIL', 'https://$DOMAIN', NOW(), 'Администратор');

-- Создаем статьи
INSERT INTO wp_posts (post_author, post_date, post_content, post_title, post_status, post_type)
VALUES 
(1, NOW(), 'Добро пожаловать на наш сайт! Здесь вы найдете интересные статьи о путешествиях, технологиях и жизни.', 'Привет, мир!', 'publish', 'post'),
(1, NOW(), 'В этой статье мы расскажем о лучших местах для отдыха в 2026 году. От пляжей Таиланда до горных курортов Швейцарии.', 'Топ-10 мест для путешествий в 2026 году', 'publish', 'post'),
(1, NOW(), 'Подробное руководство по настройке домашнего сервера на базе Ubuntu. От выбора железа до установки софта.', 'Как настроить домашний сервер на Ubuntu', 'publish', 'post');
EOF

print_success "Контент создан"

# ============================================================
# Настройка автозапуска и безопасности
# ============================================================

print_info "Настройка безопасности..."

# Отключаем XML-RPC в WordPress
cat >> /var/www/$DOMAIN/wp-config.php <<'EOF'

// Отключаем XML-RPC
add_filter('xmlrpc_enabled', '__return_false');

// Отключаем редактор файлов
define('DISALLOW_FILE_EDIT', true);

// Ограничиваем ревизии постов
define('WP_POST_REVISIONS', 3);
EOF

# Настраиваем firewall
apt install -y ufw
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable

print_success "Безопасность настроена"

# ============================================================
# Финальная информация для пользователя
# ============================================================

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
echo "   Порт:          $PANEL_PORT"
echo ""
echo -e "${BLUE}🚀 Данные для VPN (VLESS Reality):${NC}"
echo "   UUID:          $VLESS_UUID"
echo "   Private Key:   $REALITY_PRIVATE_KEY"
echo "   Public Key:    $REALITY_PUBLIC_KEY"
echo "   SNI:           $VPN_DOMAIN"
echo "   Path:          /$VPN_PATH"
echo ""
echo -e "${YELLOW}⚠️  Важно:${NC}"
echo "1. Зайдите в панель 3x-ui и создайте Inbound вручную:"
echo "   - Protocol: VLESS"
echo "   - Port: 443"
echo "   - Network: tcp"
echo "   - Security: reality"
echo "   - Fallback: /var/run/php/php${PHP_VERSION}-fpm.sock"
echo ""
echo "2. После настройки протестируйте сайт:"
echo "   - Откройте https://$DOMAIN в браузере"
echo "   - Убедитесь, что WordPress работает"
echo ""
echo "3. Настройте клиент (v2rayN, Shadowrocket, etc.) с данными выше"
echo ""
echo -e "${GREEN}Готово!${NC}"
echo ""

# Сохраняем данные в файл
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

VPN (VLESS Reality):
  UUID: $VLESS_UUID
  Private Key: $REALITY_PRIVATE_KEY
  Public Key: $REALITY_PUBLIC_KEY
  SNI: $VPN_DOMAIN
  Path: /$VPN_PATH
EOF

chmod 600 /root/vpn-setup-info.txt
print_info "Данные сохранены в /root/vpn-setup-info.txt"
