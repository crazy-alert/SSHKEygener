#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода сообщений
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_question() {
    echo -e "${BLUE}[QUESTION]${NC} $1"
}

# Функция для запроса подтверждения
confirm_action() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n] "
    else
        prompt="$prompt [y/N] "
    fi
    
    print_question "$prompt"
    read -r response
    
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        [nN][oO]|[nN])
            return 1
            ;;
        *)
            if [[ "$default" == "y" ]]; then
                return 0
            else
                return 1
            fi
            ;;
    esac
}

# Функция для отправки сообщения в Telegram
send_to_telegram() {
    local bot_token="$1"
    local chat_id="$2"
    local public_key="$3"
    local key_owner="$4"
    local server_name="$5"
    
    local message="🔐 *Новый SSH ключ сгенерирован*

👤 *Пользователь:* \`$key_owner\`
🖥️ *Сервер:* \`$server_name\`
📅 *Дата:* \`$(date +"%Y-%m-%d %H:%M:%S")\`

*Публичный ключ:*
<code>$public_key</code>

⚠️ *Сохраните этот ключ в безопасном месте!*"
    
    print_message "Отправка сообщения в Telegram..."
    
    # Отправляем сообщение с Markdown разметкой
    local response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$chat_id\",
            \"text\": \"$message\",
            \"parse_mode\": \"HTML\",
            \"disable_web_page_preview\": true
        }" \
        "https://api.telegram.org/bot$bot_token/sendMessage")
    
    # Проверяем ответ
    if echo "$response" | grep -q '"ok":true'; then
        print_message "✅ Публичный ключ успешно отправлен в Telegram"
        return 0
    else
        local error_msg=$(echo "$response" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
        print_error "❌ Ошибка отправки в Telegram: $error_msg"
        return 1
    fi
}

# Получаем информацию о системе
get_system_info() {
    local key_owner=$(whoami)
    local server_name=$(hostname)
    
    # Если есть доменное имя, используем его
    if command -v hostname >/dev/null 2>&1 && hostname -f >/dev/null 2>&1; then
        server_name=$(hostname -f)
    fi
    
    # Получаем внешний IP если возможно
    local public_ip=$(curl -s -4 ifconfig.co 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "неизвестен")
    
    echo "$key_owner" "$server_name" "$public_ip"
}

# Проверка прав root
if [[ $EUID -eq 0 ]]; then
    print_warning "Скрипт запущен от root. Будет создан ключ для root пользователя."
    USER_HOME="/root"
else
    USER_HOME="$HOME"
fi

SSH_DIR="$USER_HOME/.ssh"
KEY_FILE="$SSH_DIR/id_rsa"
KEY_FILE_PUB="$KEY_FILE.pub"
CONFIG_FILE="$SSH_DIR/config"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Получаем информацию о системе
read -r key_owner server_name public_ip <<< "$(get_system_info)"

# Создаем директорию .ssh если её нет
print_message "Проверка директории .ssh..."
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Проверяем существование ключа
key_exists=false
if [[ -f "$KEY_FILE" && -f "$KEY_FILE_PUB" ]]; then
    print_warning "SSH ключ уже существует: $KEY_FILE"
    echo ""
    
    # Показываем информацию о существующем ключе
    print_message "Информация о текущем ключе:"
    ssh-keygen -lf "$KEY_FILE_PUB"
    echo ""
    
    # Показываем комментарий ключа
    key_comment=$(ssh-keygen -l -f "$KEY_FILE_PUB" | cut -d' ' -f3-)
    print_message "Комментарий ключа: $key_comment"
    echo ""
    
    key_exists=true
elif [[ -f "$KEY_FILE" && ! -f "$KEY_FILE_PUB" ]]; then
    print_warning "Найден приватный ключ, но отсутствует публичный: $KEY_FILE"
    key_exists=true
elif [[ ! -f "$KEY_FILE" && -f "$KEY_FILE_PUB" ]]; then
    print_warning "Найден публичный ключ, но отсутствует приватный: $KEY_FILE_PUB"
    key_exists=true
fi

# Обработка существующего ключа
if [[ "$key_exists" == true ]]; then
    if confirm_action "Перезаписать существующий SSH ключ?" "n"; then
        # Создаем backup существующего ключа
        backup_dir="$SSH_DIR/backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        
        if [[ -f "$KEY_FILE" ]]; then
            cp "$KEY_FILE" "$backup_dir/"
            print_message "Приватный ключ сохранен в: $backup_dir/$(basename "$KEY_FILE")"
        fi
        
        if [[ -f "$KEY_FILE_PUB" ]]; then
            cp "$KEY_FILE_PUB" "$backup_dir/"
            print_message "Публичный ключ сохранен в: $backup_dir/$(basename "$KEY_FILE_PUB")"
        fi
        
        # Удаляем старые ключи
        rm -f "$KEY_FILE" "$KEY_FILE_PUB"
        print_message "Старые ключи удалены."
        
        # Генерируем новый ключ
        print_message "Генерация нового SSH ключа..."
        ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -C "$key_owner@$server_name-$(date +%Y%m%d)"
        
    else
        print_message "Используется существующий SSH ключ."
        
        # Проверяем целостность ключа
        if [[ -f "$KEY_FILE" && -f "$KEY_FILE_PUB" ]]; then
            print_message "Проверка целостности ключа..."
            if ssh-keygen -l -f "$KEY_FILE" >/dev/null 2>&1 && ssh-keygen -l -f "$KEY_FILE_PUB" >/dev/null 2>&1; then
                print_message "Ключ прошел проверку целостности."
            else
                print_error "Обнаружены проблемы с ключом. Рекомендуется перегенерировать."
                exit 1
            fi
        fi
    fi
else
    # Генерируем новый ключ
    print_message "Генерация нового SSH ключа..."
    ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -C "$key_owner@$server_name-$(date +%Y%m%d)"
fi

# Устанавливаем правильные права
chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE_PUB"

# Читаем публичный ключ
PUBLIC_KEY_CONTENT=$(cat "$KEY_FILE_PUB")

# Выводим публичный ключ
print_message "Публичный ключ:"
echo ""
echo "$PUBLIC_KEY_CONTENT"
echo ""

# Создаем/обновляем конфиг SSH клиента
print_message "Настройка SSH клиента..."
cat > "$CONFIG_FILE" << EOF
Host *
    PubkeyAuthentication yes
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
chmod 600 "$CONFIG_FILE"

# Отключаем аутентификацию по паролю (требует root)
if [[ $EUID -eq 0 ]]; then
    if confirm_action "Отключить аутентификацию по паролю для SSH?" "n"; then
        print_message "Отключение аутентификации по паролю..."
        
        # Создаем backup конфигурации
        backup_file="${SSHD_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$SSHD_CONFIG" "$backup_file"
        print_message "Backup конфигурации создан: $backup_file"
        
        # Отключаем аутентификацию по паролю
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
        sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
        sed -i 's/^#*UsePAM.*/UsePAM no/' "$SSHD_CONFIG"
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
        
        # Включаем аутентификацию по ключу
        sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
        
        # Проверяем синтаксис конфигурации
        if sshd -t -f "$SSHD_CONFIG"; then
            print_message "Синтаксис SSH конфигурации проверен."
            
            # Перезапускаем SSH сервер
            print_message "Перезапуск SSH сервера..."
            if systemctl is-active --quiet ssh; then
                systemctl restart ssh
            elif systemctl is-active --quiet sshd; then
                systemctl restart sshd
            else
                print_warning "SSH сервер не найден в systemd"
            fi
            
            print_warning "Аутентификация по паролю ОТКЛЮЧЕНА!"
            print_warning "Убедитесь, что у вас есть доступ по SSH ключу перед закрытием сессии!"
        else
            print_error "Ошибка в конфигурации SSH. Восстанавливаем backup..."
            cp "$backup_file" "$SSHD_CONFIG"
            print_error "Изменения отменены. Проверьте конфигурацию вручную."
        fi
        
    else
        print_message "Аутентификация по паролю не изменена."
    fi
else
    print_warning "Для отключения аутентификации по паролю запустите скрипт с правами root"
    echo "sudo $0"
fi

# Проверяем, добавлен ли ключ в агент
if command -v ssh-add >/dev/null 2>&1; then
    if confirm_action "Добавить ключ в SSH агент?" "y"; then
        print_message "Добавление ключа в SSH агент..."
        ssh-add "$KEY_FILE" 2>/dev/null && print_message "Ключ добавлен в SSH агент." || print_error "Не удалось добавить ключ в агент"
    fi
fi

# Предлагаем отправить ключ в Telegram
if confirm_action "Отправить публичный ключ в Telegram?" "n"; then
    print_message "Для отправки ключа в Telegram потребуются:"
    echo "1. Токен бота (создается через @BotFather)"
    echo "2. ID чата (можно получить через @userinfobot)"
    echo ""
    
    # Запрашиваем токен бота
    while true; do
        print_question "Введите токен бота Telegram:"
        read -r bot_token
        
        if [[ -z "$bot_token" ]]; then
            print_error "Токен бота не может быть пустым."
            continue
        fi
        
        # Проверяем формат токена (примерная проверка)
        if [[ ! "$bot_token" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
            print_error "Неверный формат токена. Пример: 1234567890:ABCdefGHIjklMnOpQRSTUvWXYZ"
            continue
        fi
        
        break
    done
    
    # Запрашиваем ID чата
    while true; do
        print_question "Введите ID чата/пользователя:"
        read -r chat_id
        
        if [[ -z "$chat_id" ]]; then
            print_error "ID чата не может быть пустым."
            continue
        fi
        
        # Проверяем, что это число (Telegram ID обычно числовой)
        if [[ ! "$chat_id" =~ ^-?[0-9]+$ ]]; then
            print_error "ID чата должен быть числом. Пример: 123456789 или -1001234567890 для групп"
            continue
        fi
        
        break
    done
    
    # Отправляем ключ в Telegram
    send_to_telegram "$bot_token" "$chat_id" "$PUBLIC_KEY_CONTENT" "$key_owner" "$server_name"
  
fi

# Инструкция для пользователя
print_message "Инструкция:"
echo "1. Скопируйте публичный ключ выше на удаленные серверы:"
echo "   ssh-copy-id -i $KEY_FILE user@hostname"
echo ""
echo "2. Для подключения используйте:"
echo "   ssh -i $KEY_FILE user@hostname"
echo ""
echo "3. Или настройте Host в файле $CONFIG_FILE"
echo ""
echo "4. Приватный ключ: $KEY_FILE"
echo "5. Публичный ключ: $KEY_FILE_PUB"

print_message "Настройка SSH завершена!"
