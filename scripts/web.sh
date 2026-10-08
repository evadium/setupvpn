#!/bin/bash
set -Eeuo pipefail

# Порты
PORT_HTTP=80
PORT_INTERNAL_TLS=8443

PORT_INTERNAL_XHTTP=10001
PORT_INTERNAL_GRPC=10002
PORT_INTERNAL_WS=10003
PORT_INTERNAL_HTTPUPGRADE=10004

# Пути
DIR_WEB_ROOT="/var/www/site"
DIR_ACME_ROOT="/var/www/letsencrypt"
FILE_VPN_SECRETS="/root/.vpn-secrets.env"
FILE_NGINX_CONF="/etc/nginx/nginx.conf"
FILE_HTTP_CONF="/etc/nginx/conf.d/00-acme-http.conf"
FILE_SECURE_CONF="/etc/nginx/conf.d/vhost-secure.conf"

DOMAIN_NAME=""
CERTIFICATE_EMAIL=""
FLAG_FORCE_MODE=false

log_info() {
    printf '\n\033[1;34m[NGINX-SETUP]\033[0m %s\n' "$*"
}

log_success() {
    printf '\033[1;32m[УСПЕХ]\033[0m %s\n' "$*"
}

log_error() {
    printf '\n\033[1;31m[ОШИБКА NGINX]\033[0m %s\n' "$*" >&2
}

exit_on_error() {
    log_error "$1"
    exit 1
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)
                DOMAIN_NAME="$2"
                shift 2
                ;;
            -e|--email)
                CERTIFICATE_EMAIL="$2"
                shift 2
                ;;
            -f|--force)
                FLAG_FORCE_MODE=true
                shift
                ;;
            -h|--help)
                echo "Использование: $0 -d <домен> [-e <email>] [-f|--force]"
                exit 0
                ;;
            *)
                exit_on_error "Неизвестный параметр: $1"
                ;;
        esac
    done
}

resolve_domain_input() {
    if [[ -z "$DOMAIN_NAME" && -n "${DOMAIN:-}" ]]; then
        DOMAIN_NAME="$DOMAIN"
    fi

    if [[ -z "$CERTIFICATE_EMAIL" && -n "${EMAIL:-}" ]]; then
        CERTIFICATE_EMAIL="$EMAIL"
    fi

    if [[ -z "$DOMAIN_NAME" ]]; then
        read -rp "Введите доменное имя для веб-сервера: " DOMAIN_NAME
    fi

    [[ -n "$DOMAIN_NAME" ]] || exit_on_error "Домен не указан"
}

check_root_and_os() {
    [[ $EUID -eq 0 ]] || exit_on_error "Запустите скрипт с правами root"

    if [[ ! -f /etc/os-release ]]; then
        exit_on_error "Не удалось определить ОС"
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *debian* ]]; then
        exit_on_error "Скрипт оптимизирован для систем Debian/Ubuntu"
    fi
}

install_packages_if_missing() {
    local missing_packages=()

    for pkg in nginx certbot openssl curl; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Установка недостающих пакетов: ${missing_packages[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${missing_packages[@]}"
}

load_or_generate_path_secrets() {
    if [[ -f "$FILE_VPN_SECRETS" ]]; then
        # shellcheck disable=SC1090
        source "$FILE_VPN_SECRETS"
        return 0
    fi

    log_info "Генерация секретных путей для транспортов Xray"
    SECRET_CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    SECRET_PATH_XHTTP=$(openssl rand -hex 6)
    SECRET_PATH_GRPC=$(openssl rand -hex 6)
    SECRET_PATH_WS=$(openssl rand -hex 6)
    SECRET_PATH_HTTPUPGRADE=$(openssl rand -hex 6)

    umask 077
    cat > "$FILE_VPN_SECRETS" <<EOF
SECRET_CLIENT_UUID=$SECRET_CLIENT_UUID
SECRET_PATH_XHTTP=$SECRET_PATH_XHTTP
SECRET_PATH_GRPC=$SECRET_PATH_GRPC
SECRET_PATH_WS=$SECRET_PATH_WS
SECRET_PATH_HTTPUPGRADE=$SECRET_PATH_HTTPUPGRADE
EOF
    umask 022
}

optimize_main_nginx_conf() {
    log_info "Оптимизация базовой конфигурации $FILE_NGINX_CONF"

    # Резервная копия оригинального файла
    if [[ ! -f "${FILE_NGINX_CONF}.backup" ]]; then
        cp "$FILE_NGINX_CONF" "${FILE_NGINX_CONF}.backup"
    fi

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 1)

    cat > "$FILE_NGINX_CONF" <<EOF
user www-data;
pid /run/nginx.pid;
worker_processes $cpu_cores;
worker_rlimit_nofile 65535;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    charset utf-8;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    log_not_found off;
    types_hash_max_size 2048;
    client_max_body_size 64M;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log off;
    error_log /var/log/nginx/error.log warn;

    # Корректная обработка WebSocket и HTTPUpgrade
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    # Сжатие статики для сайта-заглушки
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript image/svg+xml;

    include /etc/nginx/conf.d/*.conf;
}
EOF
}

deploy_stub_website() {
    mkdir -p "$DIR_WEB_ROOT" "$DIR_ACME_ROOT"

    if [[ -f "$DIR_WEB_ROOT/index.html" ]]; then
        return 0
    fi

    log_info "Создание страницы-заглушки"
    cat > "$DIR_WEB_ROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Service Portal</title>
    <style>
        body { font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        .card { max-width: 440px; padding: 2rem; background: #1e293b; border-radius: 8px; border: 1px solid #334155; }
        h1 { margin-top: 0; font-size: 1.4rem; color: #38bdf8; }
        p { color: #94a3b8; line-height: 1.5; font-size: 0.95rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Service Status: Online</h1>
        <p>This endpoint is operational. Automated status monitoring and health checks are currently active.</p>
    </div>
</body>
</html>
HTML
    chown -R www-data:www-data "$DIR_WEB_ROOT"
}

setup_acme_http_vhost() {
    log_info "Настройка временного HTTP-хоста для ACME Let's Encrypt"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/conf.d/default.conf
    rm -f "$FILE_SECURE_CONF"

    cat > "$FILE_HTTP_CONF" <<EOF
server {
    listen $PORT_HTTP default_server;
    server_name $DOMAIN_NAME;

    location /.well-known/acme-challenge/ {
        root $DIR_ACME_ROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

    nginx -t
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
}

issue_or_generate_certificate() {
    local cert_dir="/etc/letsencrypt/live/$DOMAIN_NAME"
    local fullchain="$cert_dir/fullchain.pem"
    local privkey="$cert_dir/privkey.pem"

    if [[ -f "$fullchain" && -f "$privkey" ]]; then
        log_info "Сертификат для $DOMAIN_NAME уже существует"
        return 0
    fi

    if [[ "$FLAG_FORCE_MODE" == true ]]; then
        log_info "Создаётся самоподписанный сертификат"
        mkdir -p "$cert_dir"

        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$privkey" \
            -out "$fullchain" \
            -subj "/CN=$DOMAIN_NAME" \
            -addext "subjectAltName=DNS:$DOMAIN_NAME" >/dev/null 2>&1

        log_success "Самоподписанный SSL-сертификат успешно создан для $DOMAIN_NAME"
        return 0
    fi

    log_info "Получение настоящего SSL-сертификата Let's Encrypt"
    local certbot_args=()
    if [[ -n "$CERTIFICATE_EMAIL" ]]; then
        certbot_args=(-m "$CERTIFICATE_EMAIL")
    else
        certbot_args=(--register-unsafely-without-email)
    fi

    certbot certonly --webroot \
        -w "$DIR_ACME_ROOT" \
        -d "$DOMAIN_NAME" \
        --non-interactive \
        --agree-tos \
        "${certbot_args[@]}"

    local deploy_dir="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$deploy_dir"
    cat > "$deploy_dir/reload-nginx.sh" <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
    chmod +x "$deploy_dir/reload-nginx.sh"
}

setup_internal_secure_vhost() {
    log_info "Конфигурация внутреннего SSL-хоста на 127.0.0.1:$PORT_INTERNAL_TLS"

    local listen_http2_line
    local http2_separate_directive=""

    if nginx -V 2>&1 | grep -qE 'nginx/1\.(2[5-9]|[3-9][0-9])|nginx/[2-9]'; then
        listen_http2_line="listen 127.0.0.1:$PORT_INTERNAL_TLS ssl default_server;"
        http2_separate_directive="http2 on;"
    else
        listen_http2_line="listen 127.0.0.1:$PORT_INTERNAL_TLS ssl http2 default_server;"
    fi

    cat > "$FILE_SECURE_CONF" <<EOF
server {
    $listen_http2_line
    $http2_separate_directive
    server_name $DOMAIN_NAME;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;

    root $DIR_WEB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # VLESS + XHTTP (потоковый HTTP POST без буферизации)
    location /$SECRET_PATH_XHTTP {
        proxy_pass http://127.0.0.1:$PORT_INTERNAL_XHTTP;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }

    # VLESS + gRPC
    location /$SECRET_PATH_GRPC {
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Host \$host;
        grpc_pass grpc://127.0.0.1:$PORT_INTERNAL_GRPC;
    }

    # VLESS + WebSocket
    location /$SECRET_PATH_WS {
        proxy_pass http://127.0.0.1:$PORT_INTERNAL_WS;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }

    # VLESS + HTTPUpgrade
    location /$SECRET_PATH_HTTPUPGRADE {
        proxy_pass http://127.0.0.1:$PORT_INTERNAL_HTTPUPGRADE;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
EOF

    nginx -t || exit_on_error "Сгенерированная конфигурация Nginx не прошла валидацию"
    systemctl reload nginx
    log_success "Nginx настроен и перезагружен"
}

main() {
    parse_arguments "$@"
    resolve_domain_input
    check_root_and_os
    install_packages_if_missing
    load_or_generate_path_secrets
    optimize_main_nginx_conf
    deploy_stub_website
    setup_acme_http_vhost
    issue_or_generate_certificate
    setup_internal_secure_vhost
    log_info "Модуль Web и Nginx настроен успешно"
}

main "$@"
