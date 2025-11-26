#!/bin/bash
CONFIG_FILE="/etc/hysteria/config.json"

define_colors() {
    green='\033[0;32m'
    cyan='\033[0;36m'
    red='\033[0;31m'
    yellow='\033[0;33m'
    LPurple='\033[1;35m'
    NC='\033[0m'
}

check_prerequisites() {
    if ! command -v whiptail &> /dev/null; then
        echo -e "${yellow}Installing whiptail for interactive setup...${NC}"
        apt-get update >/dev/null 2>&1
        apt-get install -qq -y whiptail || { echo -e "${red}Error: Failed to install whiptail.${NC}"; exit 1; }
    fi
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ]; then
            echo -e "${red}Error: This installer supports Ubuntu only. Detected OS: $ID.${NC}"
            exit 1
        fi
        
        MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d '.' -f 1)
        
        if [ "$MAJOR_VERSION" -lt 22 ]; then
            echo -e "${red}Error: Minimum required Ubuntu version is 22.04 (LTS). Your version is $VERSION_ID.${NC}"
            exit 1
        fi
    else
        echo -e "${red}Error: Cannot determine OS information. Installation aborted.${NC}"
        exit 1
    fi
}


install_menu_script() {
    local menu_file="/etc/hysteria/nodehys2.sh"
    local executable_link="/usr/local/bin/nodehys2"
    
    echo "Creating 'nodehys2' management menu..."
    
    cat > "$menu_file" << 'EOF_MENU'
#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
LPurple='\033[1;35m'
NC='\033[0m'

get_status() {
    local service=$1
    if systemctl is-active --quiet $service; then
        echo -e "${GREEN}Active${NC}"
    elif systemctl is-failed --quiet $service; then
        echo -e "${RED}Failed${NC}"
    else
        echo -e "${YELLOW}Inactive${NC}"
    fi
}

show_node_status() {
    clear
    echo -e "${CYAN}--- Hysteria2 Node Service Status ---${NC}"
    echo -e "  Hysteria Server: $(get_status hysteria-server.service)"
    echo -e "  Hysteria Auth:   $(get_status hysteria-auth.service)"
    echo -e "  Hysteria Traffic: $(get_status hysteria-traffic.service)"
    echo ""
    read -p "Press [Enter] to return to the menu..."
}

manage_node_full() {
    while true; do
        clear
        echo -e "${CYAN}--- Full Hysteria2 Node Management ---${NC}"
        echo -e "1) ${GREEN}Restart All Services${NC}"
        echo -e "2) ${RED}Stop All Services${NC}"
        echo -e "3) ${GREEN}Start All Services${NC}"
        echo -e "4) Show Node Status and Info"
        echo -e "5) View Hysteria Server Log"
        echo -e "6) Return to Main Menu"
        echo -e "${CYAN}----------------------------------${NC}"
        read -p "Please select an option: " manage_choice

        case $manage_choice in
            1)
                echo -e "${YELLOW}Restarting services...${NC}"
                systemctl restart hysteria-server.service hysteria-auth.service hysteria-traffic.service
                echo -e "${GREEN}✓ Restart successful.${NC}"
                sleep 2
                ;;
            2)
                echo -e "${YELLOW}Stopping services...${NC}"
                systemctl stop hysteria-server.service hysteria-auth.service hysteria-traffic.service
                echo -e "${RED}✗ Services stopped.${NC}"
                sleep 2
                ;;
            3)
                echo -e "${YELLOW}Starting services...${NC}"
                systemctl start hysteria-server.service hysteria-auth.service hysteria-traffic.service
                echo -e "${GREEN}✓ Services started.${NC}"
                sleep 2
                ;;
            4)
                show_node_status
                ;;
            5)
                clear
                echo -e "${CYAN}--- Last 20 lines of hysteria-server log ---${NC}"
                journalctl -u hysteria-server.service -n 20 --no-pager
                read -p "Press [Enter] to return to the menu..."
                ;;
            6)
                return
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

install_web_panel() {
    clear
    echo -e "${CYAN}--- Install Node Management Web Panel ---${NC}"
    
    local install_status=1
    
    if [[ -f /etc/hysteria/install_panel.sh ]]; then
        bash /etc/hysteria/install_panel.sh
        install_status=$?
    else
        echo -e "${RED}Error:${NC} Installation script /etc/hysteria/install_panel.sh not found."
    fi
    
    if [ $install_status -eq 0 ]; then
        echo -e "${GREEN}Web Panel Installation completed successfully.${NC}"
        echo -e "${LPurple}Run 'nodepanel' to manage the web panel.${NC}"
    else
        echo -e "${RED}Web Panel Installation FAILED.${NC}"
        echo -e "${YELLOW}Please check the errors above and fix the configuration, then try again.${NC}"
    fi

    read -p "Press [Enter] to return to the main menu (nodehys2)..."
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}==================================${NC}"
        echo -e "${CYAN}  Blitz-Node Hysteria2 Management Menu  ${NC}"
        echo -e "${CYAN}==================================${NC}"
        echo -e "1) ${LPurple}Full Node Service Management (Start, Stop, Status, Log)${NC}"
        echo -e "2) Install Node Management Web Panel (FastAPI + Caddy)"
        echo -e "3) ${RED}Exit Menu${NC}"
        echo -e "${CYAN}----------------------------------${NC}"
        read -p "Please select an option: " choice

        case $choice in
            1)
                manage_node_full
                ;;
            2)
                install_web_panel
                ;;
            3)
                echo -e "${YELLOW}Exiting.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

main_menu
EOF_MENU
    
    chown hysteria:hysteria "$menu_file" >/dev/null 2>&1
    chmod 750 "$menu_file"
    
    if ! ln -s "$menu_file" "$executable_link" >/dev/null 2>&1; then
        cat > "$executable_link" << EOF_WRAPPER
#!/bin/bash
exec $menu_file
EOF_WRAPPER
    fi
    chmod +x "$executable_link"
    
    echo -e "${green}✓${NC} 'nodehys2' menu script installed."
}

install_hysteria() {
    local port=$1
    local sni=$2
    local sha256
    local obfspassword
    local UUID
    local networkdef
    local panel_url
    local panel_key

    PORT=$(whiptail --inputbox "Enter Hysteria2 Port" 10 60 "443" --title "Hysteria2 Setup" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then echo -e "${red}Installation cancelled.${NC}"; exit 1; fi

    SNI=$(whiptail --inputbox "Enter SNI/Domain (e.g., example.com)" 10 60 "example.com" --title "Hysteria2 Setup" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then echo -e "${red}Installation cancelled.${NC}"; exit 1; fi

    whiptail --msgbox "Next, enter the Panel API details (URL and Key)." 8 60 --title "Panel Configuration"

    panel_url=$(whiptail --inputbox "Enter Panel API Domain and Path (e.g., https://panel.com/path/)" 10 70 --title "Panel URL" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$panel_url" ]; then echo -e "${red}Error: Panel URL required.${NC}"; exit 1; fi
    panel_url="${panel_url%/}"

    panel_key=$(whiptail --passwordbox "Enter Panel API Key" 10 70 --title "API Key" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$panel_key" ]; then echo -e "${red}Error: Panel API Key required.${NC}"; exit 1; fi

    whiptail --infobox "Starting Hysteria2 installation..." 8 60

    if [[ ! $PORT =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        whiptail --msgbox "Error: Invalid port number. Please enter a number between 1 and 65535." 10 60
        exit 1
    fi
    
    if ss -tuln | grep -q ":$PORT "; then
        whiptail --msgbox "Error: Port $PORT is already in use. Please choose another port." 10 60
        exit 1
    fi
    
    if ! id -u hysteria &> /dev/null; then
        useradd -r -s /usr/sbin/nologin hysteria
    fi

    echo "Cloning Blitz Node repository..."
    git clone https://github.com/ReturnFI/Blitz-Node /etc/hysteria >/dev/null 2>&1 || {
        echo -e "${red}Error:${NC} Failed to clone Blitz Node repository"
        exit 1
    }
    cd /etc/hysteria/
    
    echo "Downloading web panel installer..."
    wget -O /etc/hysteria/install_panel.sh https://raw.githubusercontent.com/KimiVerse/Blitz-Node/main/install_panel.sh >/dev/null 2>&1 || {
        echo -e "${red}Error:${NC} Failed to download install_panel.sh"
        exit 1
    }
    chmod +x /etc/hysteria/install_panel.sh

    echo "Installing Hysteria2 binary..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1
    
    echo "Installing Python and dependencies..."
    apt-get update 
    apt-get install -qq -y python3 python3-venv python3-pip jq

    echo "Generating CA key and certificate..."
    openssl ecparam -genkey -name prime256v1 -out ca.key >/dev/null 2>&1
    openssl req -new -x509 -days 36500 -key ca.key -out ca.crt -subj "/CN=$SNI" >/dev/null 2>&1
    
    echo "Downloading geo data and config..."
    wget -O /etc/hysteria/config.json https://raw.githubusercontent.com/ReturnFI/Blitz/refs/heads/main/config.json >/dev/null 2>&1 || {
        echo -e "${red}Error:${NC} Failed to download config.json"
        exit 1
    }
    wget -O /etc/hysteria/geosite.dat https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geosite.dat >/dev/null 2>&1
    wget -O /etc/hysteria/geoip.dat https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geoip.dat >/dev/null 2>&1

    echo "Generating SHA-256 fingerprint..."
    sha256=$(openssl x509 -noout -fingerprint -sha256 -inform pem -in ca.crt | sed 's/.*=//' | tr '[:lower:]' '[:upper:]')
    obfspassword=$(openssl rand -base64 24)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    networkdef=$(ip route | grep "^default" | awk '{print $5}')

    chown hysteria:hysteria /etc/hysteria/ca.key /etc/hysteria/ca.crt
    chmod 640 /etc/hysteria/ca.key /etc/hysteria/ca.crt

    echo "Customizing config.json..."
    jq --arg PORT "$PORT" \
       --arg sha256 "$sha256" \
       --arg obfspassword "$obfspassword" \
       --arg UUID "$UUID" \
       --arg networkdef "$networkdef" \
       '.listen = (":" + $PORT) |
        .tls.cert = "/etc/hysteria/ca.crt" |
        .tls.key = "/etc/hysteria/ca.key" |
        .tls.pinSHA256 = $sha256 |
        .obfs.salamander.password = $obfspassword |
        .trafficStats.secret = $UUID |
        .outbounds[0].direct.bindDevice = $networkdef' "$CONFIG_FILE" > "${CONFIG_FILE}.temp" && mv "${CONFIG_FILE}.temp" "$CONFIG_FILE" || {
        echo -e "${red}Error:${NC} Failed to customize config.json"
        exit 1
    }

    echo "Setting up Hysteria services..."
    if [[ -f /etc/systemd/system/hysteria-server.service ]]; then
        sed -i 's|/etc/hysteria/config.yaml|'"$CONFIG_FILE"'|g' /etc/systemd/system/hysteria-server.service
        [[ -f /etc/hysteria/config.yaml ]] && rm /etc/hysteria/config.yaml
    fi

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-server.service >/dev/null 2>&1
    systemctl restart hysteria-server.service >/dev/null 2>&1
    sleep 2

    echo "Setting up Python services (Auth/Traffic)..."
    python3 -m venv /etc/hysteria/blitz >/dev/null 2>&1
    /etc/hysteria/blitz/bin/pip install aiohttp >/dev/null 2>&1
    
    cat > /etc/hysteria/.env <<EOF
PANEL_API_URL=${panel_url}/api/v1/users/
PANEL_TRAFFIC_URL=${panel_url}/api/v1/config/ip/nodestraffic
PANEL_API_KEY=${panel_key}
SYNC_INTERVAL=35
EOF
    chown hysteria:hysteria /etc/hysteria/.env
    chmod 600 /etc/hysteria/.env
    
    cat > /etc/systemd/system/hysteria-auth.service <<EOF
[Unit]
Description=Hysteria2 Auth Service
After=network.target

[Service]
Type=simple
User=hysteria
WorkingDirectory=/etc/hysteria
Environment="PATH=/etc/hysteria/blitz/bin"
EnvironmentFile=/etc/hysteria/.env
ExecStart=/etc/hysteria/blitz/bin/python3 /etc/hysteria/auth.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/hysteria-traffic.service <<EOF
[Unit]
Description=Hysteria2 Traffic Collector
After=network.target

[Service]
Type=simple
User=hysteria
WorkingDirectory=/etc/hysteria
Environment="PATH=/etc/hysteria/blitz/bin"
EnvironmentFile=/etc/hysteria/.env
ExecStart=/etc/hysteria/blitz/bin/python3 /etc/hysteria/traffic.py
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    chown hysteria:hysteria /etc/hysteria/blitz >/dev/null 2>&1
    chmod 750 /etc/hysteria/blitz
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hysteria-auth.service hysteria-traffic.service >/dev/null 2>&1
    systemctl start hysteria-auth.service hysteria-traffic.service >/dev/null 2>&1

    install_menu_script 

    if systemctl is-active --quiet hysteria-server.service; then
        whiptail --msgbox "Hysteria2 Node Installation Complete!\n\nPort: $PORT\nSHA256: $sha256\n\nTo manage the node, run the command 'nodehys2' in the terminal." 15 70 --title "Installation Success"
        return 0
    else
        whiptail --msgbox "Warning: Hysteria2 service failed to start. Installation completed, but service is not active. Use 'nodehys2' to manage." 15 70 --title "Installation Warning"
        journalctl -u hysteria-server.service -n 20 --no-pager
        return 0
    fi
}

uninstall_hysteria() {
    echo "Uninstalling Hysteria2..."
    
    if systemctl is-active --quiet hysteria-server.service; then
        systemctl stop hysteria-server.service >/dev/null 2>&1
        systemctl disable hysteria-server.service >/dev/null 2>&1
        echo -e "${green}✓${NC} Stopped hysteria-server service"
    fi
    
    for service in hysteria-auth hysteria-traffic; do
        if systemctl is-active --quiet $service.service; then
            systemctl stop $service.service >/dev/null 2>&1
            systemctl disable $service.service >/dev/null 2>&1
            echo -e "${green}✓${NC} Stopped $service service"
        fi
        if [[ -f /etc/systemd/system/$service.service ]]; then
            rm /etc/systemd/system/$service.service >/dev/null 2>&1
        fi
    done
    
    if [[ -f /usr/local/bin/nodehys2 ]]; then
        rm /usr/local/bin/nodehys2 >/dev/null 2>&1
        echo -e "${green}✓${NC} Removed nodehys2 executable link"
    fi
    if [[ -f /etc/hysteria/nodehys2.sh ]]; then
        rm /etc/hysteria/nodehys2.sh >/dev/null 2>&1
        echo -e "${green}✓${NC} Removed nodehys2 menu file"
    fi
    
    if [[ -f /etc/hysteria/install_panel.sh ]]; then
        bash /etc/hysteria/install_panel.sh --uninstall >/dev/null 2>&1
    fi

    bash <(curl -fsSL https://get.hy2.sh/) --remove >/dev/null 2>&1
    echo -e "${green}✓${NC} Removed Hysteria2 binary"
    
    if id -u hysteria &> /dev/null; then
        userdel hysteria >/dev/null 2>&1
        echo -e "${green}✓${NC} Removed hysteria user"
    fi

    if [[ -d /etc/hysteria ]]; then
        rm -rf /etc/hysteria
        echo -e "${green}✓${NC} Removed /etc/hysteria directory"
    fi
    
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "${green}✓${NC} Hysteria2 uninstalled successfully"
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  install <port> <sni>    Install Hysteria2 with specified port and SNI"
    echo "  uninstall               Uninstall Hysteria2 completely"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 install 1239 bts.com"
    echo "  $0 uninstall"
}

define_colors

case "${1:-}" in
    install)
        check_prerequisites
        if systemctl is-active --quiet hysteria-server.service; then
            echo -e "${red}✗ Error:${NC} Hysteria2 is already installed and running"
            exit 1
        fi
        install_hysteria "" ""
        ;;
    uninstall)
        if ! systemctl is-active --quiet hysteria-server.service && [[ ! -d /etc/hysteria ]]; then
            echo -e "${yellow}⚠${NC} Hysteria2 is not installed"
            exit 0
        fi
        uninstall_hysteria
        ;;
    -h|--help)
        show_usage
        ;;
    *)
        echo -e "${red}Error:${NC} Invalid option"
        show_usage
        exit 1
        ;;
esac
