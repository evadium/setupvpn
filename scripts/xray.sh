#!/bin/bash
set -Eeuo pipefail

PORT_REALITY=443
PORT_NGINX_TLS=8443

PORT_INTERNAL_XHTTP=10001
PORT_INTERNAL_GRPC=10002
PORT_INTERNAL_WS=10003
PORT_INTERNAL_HTTPUPGRADE=10004

FILE_XRAY_CONFIG="/usr/local/etc/xray/config.json"
FILE_VPN_SECRETS="/root/.vpn-secrets.env"
FILE_WARP_CREDS="/etc/warp/warp-creds.env"
FILE_CLIENT_LINKS="/root/vless-links.txt"

DOMAIN_NAME=""

log_info() { printf '\n\033[1;34m[XRAY]\033[0m %s\n' "$*"; }
exit_on_error() { printf '\n\033[1;31m[ОШИБКА XRAY]\033[0m %s\n' "$*" >&2; exit 1; }

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain) DOMAIN_NAME="$2"; shift 2 ;;
            *) exit_on_error "Неизвестный параметр: $1" ;;
        esac
    done
}

ensure_xray_installed() {
    if command -v xray >/dev/null 2>&1; then
        return 0
    fi

    log_info "Установка ядра Xray-core"
    local installer_path="/tmp/xray-install.sh"
    curl -fsSL -o "$installer_path" https://github.com/XTLS/Xray-install/raw/main/install-release.sh
    bash "$installer_path" install
    rm -f "$installer_path"
}

load_or_create_secrets() {
    local generate_new=false

    if [[ -f "$FILE_VPN_SECRETS" ]]; then
        source "$FILE_VPN_SECRETS"
        if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
            generate_new=true
        fi
    else
        generate_new=true
    fi

    if [[ "$generate_new" == true ]]; then
        log_info "Генерация секретов Reality и путей"
        SECRET_CLIENT_UUID="${SECRET_CLIENT_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
        SECRET_PATH_XHTTP="${SECRET_PATH_XHTTP:-$(openssl rand -hex 6)}"
        SECRET_PATH_GRPC="${SECRET_PATH_GRPC:-$(openssl rand -hex 6)}"
        SECRET_PATH_WS="${SECRET_PATH_WS:-$(openssl rand -hex 6)}"
        SECRET_PATH_HTTPUPGRADE="${SECRET_PATH_HTTPUPGRADE:-$(openssl rand -hex 6)}"

        local keypair
        keypair=$(xray x25519)
        REALITY_PRIVATE_KEY=$(echo "$keypair" | awk -F': *' 'tolower($1) ~ /private/ {print $2}' | tr -d ' \r')
        REALITY_PUBLIC_KEY=$(echo "$keypair" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2}' | tr -d ' \r')
        REALITY_SHORT_ID=$(openssl rand -hex 8)

        umask 077
        cat > "$FILE_VPN_SECRETS" <<EOF
SECRET_CLIENT_UUID=$SECRET_CLIENT_UUID
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
SECRET_PATH_XHTTP=$SECRET_PATH_XHTTP
SECRET_PATH_GRPC=$SECRET_PATH_GRPC
SECRET_PATH_WS=$SECRET_PATH_WS
SECRET_PATH_HTTPUPGRADE=$SECRET_PATH_HTTPUPGRADE
EOF
        umask 022
    fi
}

format_warp_addresses_json() {
    local raw_input="$1"
    local cleaned
    cleaned=$(echo "$raw_input" | tr -d '[]" \r\n')
    echo "$cleaned" | awk -F',' '{
        printf "["
        for (i = 1; i <= NF; i++) {
            if ($i != "") printf "%s\"%s\"", (i > 1 ? ", " : ""), $i
        }
        printf "]"
    }'
}

write_xray_config() {
    [[ -f "$FILE_WARP_CREDS" ]] || exit_on_error "Файл $FILE_WARP_CREDS не найден. Сначала выполните setup-warp.sh"
    source "$FILE_WARP_CREDS"

    local warp_addresses
    warp_addresses=$(format_warp_addresses_json "${WARP_ADDRESSES_JSON:-}")

    log_info "Генерация конфигурации $FILE_XRAY_CONFIG"
    cat > "$FILE_XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },
  "dns": {
    "servers": [
      "https://1.1.1.1/dns-query",
      "https://1.0.0.1/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": $PORT_REALITY,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$SECRET_CLIENT_UUID",
            "flow": "xtls-rprx-vision",
            "email": "reality"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:$PORT_NGINX_TLS",
          "xver": 0,
          "serverNames": ["$DOMAIN_NAME"],
          "privateKey": "$REALITY_PRIVATE_KEY",
          "shortIds": ["$REALITY_SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "xhttp-in",
      "listen": "127.0.0.1",
      "port": $PORT_INTERNAL_XHTTP,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$SECRET_CLIENT_UUID", "email": "xhttp"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/$SECRET_PATH_XHTTP",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "grpc-in",
      "listen": "127.0.0.1",
      "port": $PORT_INTERNAL_GRPC,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$SECRET_CLIENT_UUID", "email": "grpc"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "$SECRET_PATH_GRPC"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "ws-in",
      "listen": "127.0.0.1",
      "port": $PORT_INTERNAL_WS,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$SECRET_CLIENT_UUID", "email": "ws"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/$SECRET_PATH_WS"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "httpupgrade-in",
      "listen": "127.0.0.1",
      "port": $PORT_INTERNAL_HTTPUPGRADE,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$SECRET_CLIENT_UUID", "email": "hu"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "/$SECRET_PATH_HTTPUPGRADE"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "warp",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "$WARP_PRIVATE_KEY",
        "address": $warp_addresses,
        "peers": [{
          "publicKey": "$WARP_PUBLIC_KEY",
          "allowedIPs": ["0.0.0.0/0", "::/0"],
          "endpoint": "$WARP_ENDPOINT_IPV4:$WARP_ENDPOINT_PORT"
        }],
        "mtu": 1280
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "warp"
      }
    ]
  }
}
EOF

    local xray_user
    xray_user=$(systemctl show -p User --value xray 2>/dev/null || true)
    xray_user="${xray_user:-nobody}"
    chown "root:$(id -gn "$xray_user" 2>/dev/null || echo nogroup)" "$FILE_XRAY_CONFIG"
    chmod 640 "$FILE_XRAY_CONFIG"

    if ! xray run -test -config "$FILE_XRAY_CONFIG"; then
        exit_on_error "Конфигурационный файл Xray содержит ошибки. Проверьте вывод выше."
    fi

    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 2

    systemctl is-active --quiet xray || exit_on_error "Служба Xray не смогла запуститься (journalctl -u xray)"
}

generate_client_links() {
    local link_reality="vless://$SECRET_CLIENT_UUID@$DOMAIN_NAME:$PORT_REALITY?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$DOMAIN_NAME&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID&type=tcp&headerType=none#$DOMAIN_NAME-Reality"
    local link_xhttp="vless://$SECRET_CLIENT_UUID@$DOMAIN_NAME:$PORT_REALITY?encryption=none&security=tls&sni=$DOMAIN_NAME&fp=chrome&alpn=h2&type=xhttp&host=$DOMAIN_NAME&path=%2F$SECRET_PATH_XHTTP&mode=auto#$DOMAIN_NAME-XHTTP"
    local link_grpc="vless://$SECRET_CLIENT_UUID@$DOMAIN_NAME:$PORT_REALITY?encryption=none&security=tls&sni=$DOMAIN_NAME&fp=chrome&alpn=h2&type=grpc&serviceName=$SECRET_PATH_GRPC&mode=gun#$DOMAIN_NAME-gRPC"
    local link_ws="vless://$SECRET_CLIENT_UUID@$DOMAIN_NAME:$PORT_REALITY?encryption=none&security=tls&sni=$DOMAIN_NAME&fp=chrome&alpn=http%2F1.1&type=ws&host=$DOMAIN_NAME&path=%2F$SECRET_PATH_WS#$DOMAIN_NAME-WebSocket"
    local link_httpupgrade="vless://$SECRET_CLIENT_UUID@$DOMAIN_NAME:$PORT_REALITY?encryption=none&security=tls&sni=$DOMAIN_NAME&fp=chrome&alpn=http%2F1.1&type=httpupgrade&host=$DOMAIN_NAME&path=%2F$SECRET_PATH_HTTPUPGRADE#$DOMAIN_NAME-HTTPUpgrade"

    umask 077
    cat > "$FILE_CLIENT_LINKS" <<EOF
# Reality
$link_reality

# Резервные подключения через Nginx:
$link_xhttp
$link_grpc
$link_ws
$link_httpupgrade
EOF
    umask 022
}

main() {
    parse_arguments "$@"
    [[ -n "$DOMAIN_NAME" ]] || exit_on_error "Укажите домен через -d <домен>"

    ensure_xray_installed
    load_or_create_secrets
    write_xray_config
    generate_client_links
    log_info "Модуль Xray сконфигурирован"
}

main "$@"
