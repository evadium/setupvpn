#!/bin/bash
set -Eeuo pipefail

DIR_WARP_CONFIG="/etc/warp"
FILE_WARP_CREDS="/etc/warp/warp-creds.env"

WARP_ENDPOINT_IPV4="162.159.192.1"
WARP_ENDPOINT_PORT="2408"
WARP_FALLBACK_VERSION="2.2.22"
PORT_CHECK_SOCKS=10808

log_info() { printf '\n\033[1;34m[WARP]\033[0m %s\n' "$*"; }
exit_on_error() { printf '\n\033[1;31m[ОШИБКА WARP]\033[0m %s\n' "$*" >&2; exit 1; }

install_wgcf() {
    if command -v wgcf >/dev/null 2>&1; then
        return 0
    fi

    log_info "Установка утилиты wgcf"
    local system_arch
    case "$(dpkg --print-architecture)" in
        amd64) system_arch="amd64" ;;
        arm64) system_arch="arm64" ;;
        armhf) system_arch="armv7" ;;
        *) exit_on_error "Неподдерживаемая архитектура" ;;
    esac

    local download_url
    download_url=$(curl -fsSL --max-time 10 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
        | grep -oE "https://[^\"]+_linux_${system_arch}" | head -n 1 || true)

    if [[ -z "$download_url" ]]; then
        download_url="https://github.com/ViRb3/wgcf/releases/download/v${WARP_FALLBACK_VERSION}/wgcf_${WARP_FALLBACK_VERSION}_linux_${system_arch}"
    fi

    curl -fsSL -o /usr/local/bin/wgcf "$download_url"
    chmod +x /usr/local/bin/wgcf
}

generate_warp_profile() {
    mkdir -p "$DIR_WARP_CONFIG"
    cd "$DIR_WARP_CONFIG"

    if [[ ! -f "wgcf-account.toml" ]]; then
        log_info "Регистрация устройства в Cloudflare WARP"
        local attempt
        for attempt in 1 2 3 4 5; do
            if wgcf register --accept-tos; then
                break
            fi
            echo "Повтор запроса к WARP ($attempt/5)..."
            sleep 6
        done
    fi

    [[ -f "wgcf-account.toml" ]] || exit_on_error "Не удалось получить аккаунт WARP"

    if [[ ! -f "wgcf-profile.conf" ]]; then
        wgcf generate
    fi

    [[ -f "wgcf-profile.conf" ]] || exit_on_error "Не найден wgcf-profile.conf"

    local private_key public_key addresses_json
    private_key=$(awk -F' *= *' '/^PrivateKey/{print $2}' wgcf-profile.conf | tr -d ' \r')
    public_key=$(awk -F' *= *' '/^PublicKey/{print $2}' wgcf-profile.conf | tr -d ' \r')
    addresses_json=$(grep -E '^Address' wgcf-profile.conf | sed 's/^Address *= *//' | tr ',' '\n' | tr -d ' \r' | sed '/^$/d' | sed 's/.*/"&"/' | paste -sd, -)

    [[ -n "$private_key" && -n "$public_key" && -n "$addresses_json" ]] || exit_on_error "Ошибка парсинга профиля WireGuard"

    umask 077
    cat > "$FILE_WARP_CREDS" <<EOF
WARP_PRIVATE_KEY="$private_key"
WARP_PUBLIC_KEY="$public_key"
WARP_ADDRESSES_JSON='[$addresses_json]'
WARP_ENDPOINT_IPV4="$WARP_ENDPOINT_IPV4"
WARP_ENDPOINT_PORT="$WARP_ENDPOINT_PORT"
EOF
    umask 022
    cd /
}

verify_warp_egress() {
    source "$FILE_WARP_CREDS"

    # Если xray ещё не установлен, тест пропускается (будет проверен позже)
    if ! command -v xray >/dev/null 2>&1; then
        log_info "Xray пока не установлен, тест выхода WARP отложен"
        return 0
    fi

    log_info "Тестирование подключения через WARP"
    local temp_config="/tmp/xray-warp-test.json"
    local temp_log="/tmp/xray-warp-test.log"

    cat > "$temp_config" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": $PORT_CHECK_SOCKS, "protocol": "socks", "settings": {"udp": false}}],
  "outbounds": [{
    "tag": "warp",
    "protocol": "wireguard",
    "settings": {
      "secretKey": "$WARP_PRIVATE_KEY",
      "address": [$WARP_ADDRESSES_JSON],
      "peers": [{
        "publicKey": "$WARP_PUBLIC_KEY",
        "allowedIPs": ["0.0.0.0/0", "::/0"],
        "endpoint": "$WARP_ENDPOINT_IPV4:$WARP_ENDPOINT_PORT"
      }],
      "mtu": 1280
    }
  }]
}
EOF

    xray run -config "$temp_config" >"$temp_log" 2>&1 &
    local test_pid=$!
    sleep 3

    local warp_trace=""
    local i
    for i in 1 2 3; do
        warp_trace=$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:$PORT_CHECK_SOCKS" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
        if grep -qE '^warp=(on|plus)' <<<"$warp_trace"; then
            break
        fi
        sleep 2
    done

    kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
    rm -f "$temp_config"

    if ! grep -qE '^warp=(on|plus)' <<<"$warp_trace"; then
        cat "$temp_log" >&2
        rm -f "$temp_log"
        exit_on_error "WARP недоступен. Проверьте, не блокирует ли хостинг порт UDP $WARP_ENDPOINT_PORT"
    fi

    rm -f "$temp_log"
    local exit_ip
    exit_ip=$(awk -F= '/^ip=/{print $2}' <<<"$warp_trace")
    log_info "Подключение к WARP подтверждено. Исходящий IP: $exit_ip"
}

main() {
    install_wgcf
    generate_warp_profile
    verify_warp_egress
    log_info "Модуль Cloudflare WARP готов к работе"
}

main "$@"
