#!/bin/bash
set -Eeuo pipefail

export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

REPO_URL="https://raw.githubusercontent.com/evadium/setupvpn/refs/heads/main/scripts"

# Конфигурационные файлы
FILE_VPN_SECRETS="/root/.vpn-secrets.env"
FILE_CLIENT_LINKS="/root/vless-links.txt"

# Дефолтные переменные
DOMAIN_NAME=""
CERTIFICATE_EMAIL=""
REPO_RAW_URL="${REPO_URL:-$REPO_URL}"
FORCE_DNS_CHECK=false
SKIP_FIREWALL=false

log_info() {
    printf '\n\033[1;34m[ИНФО]\033[0m %s\n' "$*"
}

log_success() {
    printf '\033[1;32m[УСПЕХ]\033[0m %s\n' "$*"
}

log_error() {
    printf '\n\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2
}

exit_on_error() {
    log_error "$1"
    exit 1
}

show_help() {
    cat <<EOF
Использование: $0 [ПАРАМЕТРЫ]

Параметры:
  -d, --domain <домен>      Доменное имя сервера (обязательно)
  -e, --email <email>       Email для регистрации Let's Encrypt (необязательно)
  -r, --repo-url <ссылка>   Базовая ссылка репозитория с модулями (необязательно)
  -f, --force               Пропустить проверку A-записи DNS (необязательно)
      --no-ufw              Не настраивать фаервол UFW (необязательно)
  -h, --help                Показать справку
  
Пример:
  $0 -d example.com -e admin@example.com
EOF
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
            -r|--repo-url)
                REPO_RAW_URL="$2"
                shift 2
                ;;
            -f|--force)
                FORCE_DNS_CHECK=true
                shift
                ;;
            --no-ufw)
                SKIP_FIREWALL=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                exit_on_error "Неизвестный параметр: $1"
                ;;
        esac
    done
}

validate_inputs() {
    if [[ -z "$DOMAIN_NAME" && -n "${DOMAIN:-}" ]]; then
        DOMAIN_NAME="$DOMAIN"
    fi

    if [[ -z "$CERTIFICATE_EMAIL" && -n "${EMAIL:-}" ]]; then
        CERTIFICATE_EMAIL="$EMAIL"
    fi

    if [[ -z "$DOMAIN_NAME" ]]; then
        read -rp "Введите домен: " DOMAIN_NAME </dev/tty
    fi

    [[ -n "$DOMAIN_NAME" ]] || exit_on_error "Домен не указан"
}

check_environment() {
    [[ $EUID -eq 0 ]] || exit_on_error "Запустите скрипт с правами root (sudo)"

    if [[ ! -f /etc/os-release ]]; then
        exit_on_error "Не удалось определить ОС"
    fi

    source /etc/os-release
    if [[ "${ID:-}" != "debian" && "${ID_LIKE:-}" != *debian* ]]; then
        exit_on_error "Скрипт рассчитан на Debian/Ubuntu"
    fi
}

install_core_packages() {
    log_info "Установка системных пакетов"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates openssl nginx certbot ufw iproute2
}

verify_dns() {
    if [[ "$FORCE_DNS_CHECK" == true ]]; then
        log_info "Проверка DNS пропущена"
        return 0
    fi

    log_info "Проверка A-записи DNS для $DOMAIN_NAME"
    local server_ip
    local domain_ip

    server_ip=$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
    domain_ip=$(getent ahostsv4 "$DOMAIN_NAME" 2>/dev/null | awk 'NR==1{print $1}' || true)

    echo "IP сервера: ${server_ip:-не определён}"
    echo "A-запись $DOMAIN_NAME: ${domain_ip:-не найдена}"

    if [[ -z "$server_ip" || -z "$domain_ip" || "$server_ip" != "$domain_ip" ]]; then
        exit_on_error "A-запись домена $DOMAIN_NAME не указывает на $server_ip. Отключите проксирование (Cloudflare WARP) или используйте флаг --force"
    fi

    log_success "DNS-запись подтверждена"
}

run_remote_module() {
    local script_name="$1"
    shift

    log_info "Вызов модуля $script_name"

    # Если модуль есть в этой же папке то используем его, если нету то с репозитория
    if [[ -f "./$script_name" ]]; then
        bash "./$script_name" "$@"
        return 0
    fi

    local script_url="${REPO_RAW_URL%/}/$script_name"
    local temp_file
    temp_file=$(mktemp "/tmp/${script_name}.XXXXXX")

    if ! curl -fsSL "$script_url" -o "$temp_file"; then
        rm -f "$temp_file"
        exit_on_error "Не удалось скачать модуль по адресу: $script_url"
    fi

    bash "$temp_file" "$@"
    local exit_status=$?
    rm -f "$temp_file"

    if [[ $exit_status -ne 0 ]]; then
        exit_on_error "Модуль $script_name завершился с ошибкой (код: $exit_status)"
    fi
}

enable_bbr() {
    log_info "Включение TCP BBR"
    cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
}

setup_firewall() {
    if [[ "$SKIP_FIREWALL" == true ]]; then
        log_info "Настройка фаервола UFW пропущена"
        return 0
    fi

    log_info "Настройка UFW"
    local ssh_ports
    ssh_ports=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -u || true)
    ssh_ports="${ssh_ports:-22}"

    local port
    for port in $ssh_ports; do
        ufw allow "$port/tcp" >/dev/null
    done

    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw --force enable >/dev/null
    log_success "Фаервол настроен (открыты SSH: $ssh_ports, 80, 443)"
}

main() {
    parse_arguments "$@"
    validate_inputs
    check_environment
    install_core_packages
    verify_dns

    # Настройка Cloudflare WARP
    run_remote_module "warp.sh"

    # Настройка сайта, сертификата и Nginx
    run_remote_module "web.sh" -d "$DOMAIN_NAME" ${CERTIFICATE_EMAIL:+-e "$CERTIFICATE_EMAIL"}

    # Настройка Xray и генерация ссылок
    run_remote_module "xray.sh" -d "$DOMAIN_NAME"

    enable_bbr
    setup_firewall

    log_success "Скрипт успешно завершен!"
    echo "Сайт: https://$DOMAIN_NAME"
    echo "Конфигурации: $FILE_CLIENT_LINKS"
    echo
    cat "$FILE_CLIENT_LINKS"
    echo
}

main "$@"
