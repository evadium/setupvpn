# Скрипты на установку VPN для серверов

## Быстрый старт
```bash
# bash <(curl -fsSL https://raw.githubusercontent.com/evadium/setupvpn/refs/heads/main/scripts/setup.sh) --domain example.com
```

## Функции
- Установка и настройка [Cloudflare WARP CLI](https://github.com/ViRb3/wgcf) от [ViRb3](https://github.com/ViRb3)
- Установка и настройка [Nginx](https://packages.debian.org/stable/nginx) и [Certbot](https://packages.debian.org/stable/certbot)
- Добавление пустого (шаблонного) сайта (для заглушки)
- Установка и настройка [Xray](https://github.com/XTLS/Xray-install) от [XTLS](https://github.com/XTLS)
- Генерация конфигураций VLESS (Reality, XHTTP, gRPC, WebSocket, HTTPUpgrade) которые сохраняются в `/root/vless-links.txt`
- Включение [TCP BBR](https://cloud.google.com/blog/products/networking/tcp-bbr-congestion-control-comes-to-gcp-your-internet-just-got-faster)
- Установка и настройка [UFW](https://packages.debian.org/stable/ufw)

### Использование
Введите в терминал вашего сервера от имени root (sudo), заменяя "ПАРАМЕТРЫ" на ваши предпочитаемые параметры:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/evadium/setupvpn/refs/heads/main/scripts/setup.sh) ПАРАМЕТРЫ
```
#### Параметры
| Опция              |                Описание               |     Статус    | Пример                                                                                  |
|--------------------|:-------------------------------------:|:-------------:|-----------------------------------------------------------------------------------------|
| `--domain`, `-d`   | Доменное имя сервера                  | Обязательно   | `--domain example.com`                                                                  |
| `--email`, `-e`    | Email для регистрации Let's Encrypt   | Необязательно | `--email example@example.com`                                                           |
| `--repo-url`, `-r` | Базовая ссылка репозитория с модулями | Необязательно | `--repo-url https://raw.githubusercontent.com/evadium/setupvpn/refs/heads/main/scripts` |
| `--force`, `-f`    | Пропустить проверку A-записи DNS      | Необязательно | `--force`                                                                               |
| `--no-ufw`         | Не настраивать фаервол UFW            | Необязательно | `--no-ufw`                                                                              |
| `--help, -h`       | Показать справку                      | Информация    | `--help`                                                                                |

Скрипт также можно использовать по модулям:
| Модуль |       Параметры       | Описание                                                                                    | Пример                                                                                                                                                    |
|--------|:---------------------:|---------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| warp   | -                     |                            Установка и настройка Cloudflare WARP                            | `# bash <(curl -fsSL https://raw.githubusercontent.com/evadium/setupvpn/refs/heads/main/scripts/warp.sh)`                                                 |
| web    | `--domain`, `--email` | Установка и настройка Nginx и Certbot. Добавление пустого (шаблонного) сайта (для заглушки) | `# bash <(curl -fsSL https://raw.githubusercontent.com/evadium/setupvpn/refs/heads/main/scripts/web.sh) --domain example.com --email example@example.com` |
| xray   | `--domain`            | Установка и настройка Xray, генерация VLESS конфигураций                                    | `# bash <(curl -fsSL https://raw.githubusercontent.com/evadium/setupvpn/refs/heads/main/scripts/xray.sh) --domain example.com`                            |

### Требования
- Операционная система: Debian/Ubuntu
