#!/bin/bash
set -Eeuo pipefail

PORT_HTTP=80
PORT_INTERNAL_TLS=8443

PORT_INTERNAL_XHTTP=10001
PORT_INTERNAL_GRPC=10002
PORT_INTERNAL_WS=10003
PORT_INTERNAL_HTTPUPGRADE=10004

DIR_WEB_ROOT="/var/www/site"
DIR_ACME_ROOT="/var/www/letsencrypt"
FILE_VPN_SECRETS="/root/.vpn-secrets.env"

DOMAIN_NAME=""
CERTIFICATE_EMAIL=""

log_info() { printf '\n\033[1;34m[WEB]\033[0m %s\n' "$*"; }
exit_on_error() { printf '\n\033[1;31m[ОШИБКА WEB]\033[0m %s\n' "$*" >&2; exit 1; }

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) DOMAIN_NAME="$2"; shift 2 ;;
            -e|--email) CERTIFICATE_EMAIL="$2"; shift 2 ;;
            *) exit_on_error "Неизвестный параметр: $1" ;;
        esac
    done
}

ensure_secrets_exist() {
    if [[ -f "$FILE_VPN_SECRETS" ]]; then
        # shellcheck disable=SC1090
        source "$FILE_VPN_SECRETS"
        return 0
    fi

    # Генерация путей-секретов, если модуль запущен раньше основного Xray
    log_info "Инициализация секретных путей транспортов"
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

create_website_content() {
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
        .card { max-width: 480px; padding: 2rem; background: #1e293b; border-radius: 8px; border: 1px solid #334155; }
        h1 { margin-top: 0; font-size: 1.4rem; color: #38bdf8; }
        p { color: #94a3b8; line-height: 1.5; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Service Status: Online</h1>
        <p>Operational endpoint. Automated diagnostic health checks are active.</p>
    </div>
</body>
</html>
HTML
}

setup_acme_http() {
    log_info "Настройка Nginx для ACME-проверки"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/conf.d/vhost-secure.conf

    cat > /etc/nginx/conf.d/00-acme-http.conf <<EOF
server {
    listen $PORT_HTTP default_server;
    server_name $DOMAIN_NAME;
    access_log off;
    server_tokens off;

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

obtain_certificate() {
    local cert_dir="/etc/letsencrypt/live/$DOMAIN_NAME"
    if [[ -f "$cert_dir/fullchain.pem" && -f "$cert_dir/privkey.pem" ]]; then
        log_info "Сертификат Let's Encrypt уже существует"
        return 0
    fi

    log_info "Выпуск SSL-сертификата"
    local certbot_options=()
    if [[ -n "$CERTIFICATE_EMAIL" ]]; then
        certbot_options=(-m "$CERTIFICATE_EMAIL")
    else
        certbot_options=(--register-unsafely-without-email)
    fi

    certbot certonly --webroot \
        -w "$DIR_ACME_ROOT" \
        -d "$DOMAIN_NAME" \
        --non-interactive \
        --agree-tos \
        "${certbot_options[@]}"

    local deploy_dir="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$deploy_dir"
    cat > "$deploy_dir/reload-nginx.sh" <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
    chmod +x "$deploy_dir/reload-nginx.sh"
}

setup_secure_reverse_proxy() {
    log_info "Настройка внутреннего SSL-сервера Nginx на порту $PORT_INTERNAL_TLS"

    cat > /etc/nginx/conf.d/vhost-secure.conf <<EOF
server {
    listen 127.0.0.1:$PORT_INTERNAL_TLS ssl http2 default_server;
    server_name $DOMAIN_NAME;
    access_log off;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;

    root $DIR_WEB_ROOT;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # VLESS + XHTTP
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
        proxy_set_header Connection "upgrade";
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
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
EOF

    nginx -t
    systemctl reload nginx
}

main() {
    parse_arguments "$@"
    [[ -n "$DOMAIN_NAME" ]] || exit_on_error "Укажите домен через -d <домен>"

    ensure_secrets_exist
    create_website_content
    setup_acme_http
    obtain_certificate
    setup_secure_reverse_proxy
    log_info "Модуль Web и Nginx настроен успешно"
}

main "$@"
