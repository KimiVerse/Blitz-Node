#!/bin/bash

# --- Color Definitions ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
LPurple='\033[1;35m'
NC='\033[0m' # No Color

# --- Variables ---
INSTALL_DIR="/etc/hysteria"
FASTAPI_PORT_DEFAULT="8000" # Default internal port for FastAPI
PANEL_USER_DOMAIN=""
FASTAPI_PORT=""
RANDOM_PATH=""

# --- Utility Functions ---

install_caddy() {
    echo -e "${CYAN}Installing Caddy Web Server...${NC}"
    apt-get install -qq -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/cfg/setup/bash.deb.sh' | sudo -E bash >/dev/null 2>&1
    apt-get update >/dev/null 2>&1
    apt-get install -qq -y caddy
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error:${NC} Failed to install Caddy.${NC}"
        return 1
    fi
    systemctl stop caddy >/dev/null 2>&1
    echo -e "${GREEN}✓${NC} Caddy installed successfully.${NC}"
    return 0
}

validate_and_get_inputs() {
    PANEL_USER_DOMAIN=$(whiptail --inputbox "Enter Domain or Public IP for Web Panel Access" 10 70 "$PANEL_USER_DOMAIN" --title "Web Panel Access Host" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$PANEL_USER_DOMAIN" ]; then
        whiptail --msgbox "Error: Web Panel Host (Domain/IP) is required." 10 60
        return 1
    fi
    PANEL_USER_DOMAIN=$(echo "$PANEL_USER_DOMAIN" | tr '[:upper:]' '[:lower:]')

    FASTAPI_PORT=$(whiptail --inputbox "Enter Port for Panel Access (This will be the external Caddy port and internal FastAPI port)" 10 70 "$FASTAPI_PORT_DEFAULT" --title "Panel Access Port" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ] || [ -z "$FASTAPI_PORT" ]; then
        whiptail --msgbox "Error: Panel Access Port is required." 10 60
        return 1
    fi
    
    if [[ ! $FASTAPI_PORT =~ ^[0-9]+$ ]] || (( FASTAPI_PORT < 1024 || FASTAPI_PORT > 65535 )); then
        whiptail --msgbox "Error: Invalid port number. Must be between 1024 and 65535." 10 60
        return 1
    fi
    
    if ss -tuln | grep -q ":$FASTAPI_PORT "; then
        whiptail --msgbox "Error: Port $FASTAPI_PORT is already in use. Please choose another port." 10 60
        return 1
    fi

    RANDOM_PATH=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 16)
    
    return 0
}

setup_fastapi_and_services() {
    echo -e "${CYAN}Setting up FastAPI backend and services...${NC}"

    # Install Python dependencies
    cd "$INSTALL_DIR"
    /etc/hysteria/blitz/bin/pip install uvicorn python-dotenv fastapi >/dev/null 2>&1

    # 1. Write panel_api.py (FastAPI Backend)
    cat > "$INSTALL_DIR/panel_api.py" << EOF_API
import os
import subprocess
from fastapi import FastAPI, Header, HTTPException
from dotenv import load_dotenv

load_dotenv(dotenv_path="$INSTALL_DIR/.env")
PANEL_SECRET_KEY = os.getenv("PANEL_API_KEY")

if not PANEL_SECRET_KEY:
    raise RuntimeError("PANEL_API_KEY not found in .env file.")

API_KEY_NAME = "X-Admin-Key"

app = FastAPI(
    title="Blitz Node Management API",
    description="Local API for managing Hysteria2 node services."
)

def run_command(command: list):
    try:
        process = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=True
        )
        return {"output": process.stdout.strip(), "error": None}
    except subprocess.CalledProcessError as e:
        return {"output": e.stdout.strip(), "error": e.stderr.strip()}
    except FileNotFoundError:
        return {"output": None, "error": f"Command not found: {command[0]}"}

def check_admin_key(api_key: str = Header(..., alias=API_KEY_NAME)):
    if api_key != PANEL_SECRET_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized: Invalid Admin Key")

@app.get("/health")
async def health_check():
    return {"status": "ok", "message": "Node Management API is active."}

@app.get("/status/{service_name}")
async def get_service_status(service_name: str, admin_key: None = Header(None, alias=API_KEY_NAME)):
    check_admin_key(admin_key)
    
    if service_name not in ["hysteria-server", "hysteria-auth", "hysteria-traffic", "panel-api"]:
        raise HTTPException(status_code=400, detail="Invalid service name.")
        
    cmd = ["systemctl", "status", f"{service_name}.service", "--no-pager"]
    result = run_command(cmd)
    
    status_line = next((line for line in result["output"].splitlines() if line.strip().startswith("Active:")), "Active: unknown")
    
    return {
        "service": service_name,
        "active_status": status_line.split(':', 1)[-1].strip(),
        "details": result["output"]
    }

@app.post("/action/{service_name}/{action}")
async def service_action(service_name: str, action: str, admin_key: None = Header(None, alias=API_KEY_NAME)):
    check_admin_key(admin_key)

    if service_name not in ["hysteria-server", "hysteria-auth", "hysteria-traffic"]:
        raise HTTPException(status_code=400, detail="Invalid service name.")

    if action not in ["start", "stop", "restart"]:
        raise HTTPException(status_code=400, detail="Invalid action. Must be start, stop, or restart.")

    cmd = ["systemctl", action, f"{service_name}.service"]
    result = run_command(cmd)

    if result["error"]:
        return {"status": "failed", "message": f"Failed to {action} {service_name}", "error": result["error"]}

    return {"status": "success", "message": f"{service_name} {action}ed successfully."}

@app.get("/logs/{service_name}")
async def get_service_logs(service_name: str, lines: int = 20, admin_key: None = Header(None, alias=API_KEY_NAME)):
    check_admin_key(admin_key)

    if service_name not in ["hysteria-server", "hysteria-auth", "hysteria-traffic", "panel-api"]:
        raise HTTPException(status_code=400, detail="Invalid service name.")

    cmd = ["journalctl", "-u", f"{service_name}.service", "-n", str(lines), "--no-pager"]
    result = run_command(cmd)
    
    return {"service": service_name, "logs": result["output"]}
EOF_API

    # 2. Write panel-api.service (Systemd Service)
    cat > "/etc/systemd/system/panel-api.service" << EOF_SERVICE
[Unit]
Description=Blitz Node Management API (FastAPI)
After=network.target

[Service]
Type=simple
User=hysteria
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/blitz/bin"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/blitz/bin/uvicorn panel_api:app --host 127.0.0.1 --port $FASTAPI_PORT
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable panel-api.service >/dev/null 2>&1
    systemctl start panel-api.service >/dev/null 2>&1
    sleep 3
    
    if ! systemctl is-active --quiet panel-api.service; then
        echo -e "${RED}Error:${NC} Failed to start panel-api.service. Check logs: journalctl -u panel-api.service${NC}"
        return 1
    fi

    echo -e "${GREEN}✓${NC} FastAPI service configured and started on port $FASTAPI_PORT.${NC}"
    return 0
}

setup_frontend() {
    echo -e "${CYAN}Creating web panel frontend files...${NC}"
    mkdir -p "$INSTALL_DIR/web_panel"
    
    # 1. Write index.html (Simple HTML/JS Frontend)
    cat > "$INSTALL_DIR/web_panel/index.html" << EOF_HTML
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Blitz Node Management Panel</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; background-color: #f4f4f4; }
        .container { background-color: #fff; padding: 30px; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); max-width: 800px; margin: auto; }
        h1 { color: #007bff; }
        .service-status { margin-top: 20px; padding: 15px; border: 1px solid #ccc; border-radius: 4px; }
        button { padding: 8px 12px; margin: 5px; cursor: pointer; background-color: #28a745; color: white; border: none; border-radius: 4px; }
        .status { font-weight: bold; }
        .success { color: green; }
        .fail { color: red; }
        pre { background: #eee; padding: 10px; white-space: pre-wrap; word-wrap: break-word; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hysteria2 Node Management</h1>
        <p>Access Path: <strong>/$RANDOM_PATH/</strong></p>
        <div class="service-status">
            <h2>Service Management</h2>
            <div id="service-status-hys">Hysteria Server: <span class="status">...</span></div>
            <div id="service-status-auth">Auth Service: <span class="status">...</span></div>
            <div id="service-status-traffic">Traffic Collector: <span class="status">...</span></div>
            <div id="service-status-panel">Panel API: <span class="status">...</span></div>
            <button onclick="checkAllStatus()">Refresh All Status</button>
            <button onclick="actionService('hysteria-server', 'restart')">Restart Hysteria</button>
            <button onclick="actionService('hysteria-auth', 'restart')">Restart Auth</button>
        </div>
        <div id="logs-area" class="service-status" style="display:none;">
            <h2>Logs (Last 50 Lines)</h2>
            <select id="log-select">
                <option value="hysteria-server">Hysteria Server</option>
                <option value="hysteria-auth">Auth Service</option>
                <option value="hysteria-traffic">Traffic Collector</option>
                <option value="panel-api">Panel API</option>
            </select>
            <button onclick="viewLogs()">View Logs</button>
            <pre id="log-content"></pre>
        </div>
    </div>

    <script>
        const API_PATH = "/$RANDOM_PATH/api";
        const ADMIN_KEY = prompt("Enter Admin Key (PANEL_API_KEY):"); 

        if (!ADMIN_KEY) {
            alert("Admin Key is required. Reload to try again.");
            document.body.innerHTML = '<h1>Access Denied</h1><p>Admin Key is required.</p>';
        }

        async function apiCall(endpoint, method = 'GET') {
            try {
                const url = \`\${API_PATH}/\${endpoint}\`;
                const response = await fetch(url, {
                    method: method,
                    headers: { 'X-Admin-Key': ADMIN_KEY }
                });
                if (response.status === 401) throw new Error('Unauthorized');
                return await response.json();
            } catch (error) {
                console.error('API Call Error:', error);
                if (error.message === 'Unauthorized') {
                    alert('Invalid Admin Key. Please reload and try again.');
                    document.body.innerHTML = '<h1>Access Denied</h1><p>Invalid Admin Key.</p>';
                }
                return { status: 'error', message: 'Network or API failure' };
            }
        }

        async function checkStatus(service) {
            const result = await apiCall(\`status/\${service}\`);
            const statusElement = document.querySelector(\`#service-status-\${service} .status\`);
            
            if (!statusElement) return;

            if (result.active_status) {
                statusElement.textContent = result.active_status;
                if (result.active_status.includes('active')) {
                    statusElement.className = 'status success';
                } else if (result.active_status.includes('failed')) {
                    statusElement.className = 'status fail';
                } else {
                    statusElement.className = 'status';
                }
            } else {
                 statusElement.textContent = 'ERROR';
                 statusElement.className = 'status fail';
            }
        }
        
        function checkAllStatus() {
            checkStatus('hysteria-server');
            checkStatus('hysteria-auth');
            checkStatus('hysteria-traffic');
            checkStatus('panel-api');
            document.getElementById('logs-area').style.display = 'block';
        }

        async function actionService(service, action) {
            const confirmation = confirm(\`Are you sure you want to \${action} \${service}?\`);
            if (!confirmation) return;
            
            const result = await apiCall(\`action/\${service}/\${action}\`, 'POST');
            alert(\`\${service} \${action}: \${result.message}\`);
            checkAllStatus();
        }
        
        async function viewLogs() {
            const service = document.getElementById('log-select').value;
            const logContent = document.getElementById('log-content');
            logContent.textContent = 'Loading logs...';
            
            const result = await apiCall(\`logs/\${service}?lines=50\`);
            
            if (result.logs) {
                l
                ogContent.textContent = result.logs;
            } else {
                logContent.textContent = result.message || 'Failed to load logs.';
            }
        }
        
        checkAllStatus(); 
    </script>
</body>
</html>
EOF_HTML
    
    chown -R hysteria:hysteria "$INSTALL_DIR/web_panel"
    echo -e "${GREEN}✓${NC} Frontend files created.${NC}"
    return 0
}

setup_caddy() {
    echo -e "${CYAN}Configuring Caddy with host: ${PANEL_USER_DOMAIN}:${FASTAPI_PORT}...${NC}"

    cat > "/etc/caddy/Caddyfile" << EOF_CADDY
$PANEL_USER_DOMAIN:$FASTAPI_PORT {
    # Set the root for static files (index.html)
    root *$INSTALL_DIR/web_panel
    
    # Set a simple security header
    header /* X-Frame-Options DENY
    
    # Define the matcher for API calls that include the random path
    @api_calls {
        path /$RANDOM_PATH/api/*
    }

    # Handle the API calls:
    handle @api_calls {
        # 1. Remove the random path prefix (e.g., /random/api/status -> /api/status)
        uri strip_prefix /$RANDOM_PATH
        
        # 2. Proxy the modified path to the internal FastAPI server
        reverse_proxy 127.0.0.1:$FASTAPI_PORT
    }

    # Handle all other requests (the random path itself for index.html)
    handle_path /$RANDOM_PATH {
        file_server {
            index index.html
        }
    }

    # Default handle for root access (optional, can be disabled for security)
    handle / {
        file_server {
            index index.html
        }
    }
}
EOF_CADDY

    caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1
    caddy validate --config /etc/caddy/Caddyfile
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error:${NC} Caddyfile validation failed. Reverting installation.${NC}"
        return 1
    fi
    
    systemctl start caddy
    sleep 3

    if ! systemctl is-active --quiet caddy.service; then
        echo -e "${RED}Fatal Error:${NC} Caddy failed to start on port ${FASTAPI_PORT}. Check firewall rules.${NC}"
        journalctl -u caddy.service -n 10 --no-pager
        return 1
    fi

    echo -e "${GREEN}✓${NC} Caddy configured and running on ${PANEL_USER_DOMAIN}:${FASTAPI_PORT}.${NC}"
    return 0
}

create_panel_menu() {
    local menu_file="/usr/local/bin/nodepanel"
    
    echo -e "${CYAN}Creating Web Panel Management Menu...${NC}"
    
    local ADMIN_KEY_ENV
    if [ -f "$INSTALL_DIR/.env" ]; then
        ADMIN_KEY_ENV=$(grep PANEL_API_KEY "$INSTALL_DIR/.env" | cut -d '=' -f 2)
    fi

    local PANEL_URL="http://${PANEL_USER_DOMAIN}:${FASTAPI_PORT}/$RANDOM_PATH"

    cat > "$menu_file" << EOF_MENU
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
PANEL_DOMAIN="${PANEL_USER_DOMAIN}"
PANEL_URL="${PANEL_URL}"
PANEL_KEY="${ADMIN_KEY_ENV}"
FASTAPI_INTERNAL_PORT="$FASTAPI_PORT"

manage_panel_full() {
    while true; do
        clear
        echo -e "${CYAN}--- Web Panel Management (nodepanel) ---${NC}"
        echo -e "Access URL: ${GREEN}\$PANEL_URL${NC}"
        echo -e "Admin Key:  ${GREEN}\$PANEL_KEY${NC}"
        echo -e "Internal Port: ${GREEN}\$FASTAPI_INTERNAL_PORT${NC}"
        echo -e "1) ${GREEN}Restart Panel Services (FastAPI & Caddy)${NC}"
        echo -e "2) Check Panel Service Status"
        echo -e "3) View Panel API Log"
        echo -e "4) ${RED}Uninstall Web Panel${NC}"
        echo -e "5) Return to Main Menu (nodehys2)"
        echo -e "${CYAN}----------------------------------------${NC}"
        read -p "Please select an option: " manage_choice

        case \$manage_choice in
            1)
                echo -e "${YELLOW}Restarting services...${NC}"
                systemctl restart panel-api.service caddy.service
                echo -e "${GREEN}✓ Restart successful.${NC}"
                sleep 2
                ;;
            2)
                systemctl status panel-api.service caddy.service --no-pager
                read -p "Press [Enter] to return..."
                ;;
            3)
                journalctl -u panel-api.service -n 20 --no-pager
                read -p "Press [Enter] to return..."
                ;;
            4)
                bash $INSTALL_DIR/install_panel.sh --uninstall
                exit 0
                ;;
            5)
                return
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
    done
}

manage_panel_full
EOF_MENU
    
    chmod +x "$menu_file"
    echo -e "${GREEN}✓${NC} 'nodepanel' management script created and executable.${NC}"
}

# --- Main Installation Logic ---

if [[ "$1" == "--uninstall" ]]; then
    whiptail --yesno "Are you sure you want to completely uninstall the Web Panel? (Panel API and Caddy config will be removed)" 10 60
    if [ $? -ne 0 ]; then exit 0; fi
    
    systemctl stop panel-api.service caddy.service >/dev/null 2>&1
    systemctl disable panel-api.service >/dev/null 2>&1
    rm -f /etc/systemd/system/panel-api.service
    rm -rf $INSTALL_DIR/web_panel
    rm -f $INSTALL_DIR/panel_api.py
    rm -f /usr/local/bin/nodepanel
    
    # Minimal Caddy config cleanup
    caddy_config=$(cat /etc/caddy/Caddyfile 2>/dev/null)
    if echo "$caddy_config" | grep -q "$PANEL_USER_DOMAIN"; then
        echo -e "${YELLOW}Warning:${NC} Please manually clean up $PANEL_USER_DOMAIN configuration from /etc/caddy/Caddyfile.${NC}"
    fi
    
    echo -e "${GREEN}✓${NC} Web Panel uninstalled successfully.${NC}"
    exit 0
fi

# 1. Get Inputs
validate_and_get_inputs
if [ $? -ne 0 ]; then exit 1; fi

whiptail --infobox "Starting Web Panel installation for https://${PANEL_USER_DOMAIN}/$RANDOM_PATH..." 8 60

# 2. Install Caddy
install_caddy
if [ $? -ne 0 ]; then exit 1; fi

# 3. Setup FastAPI and Services
setup_fastapi_and_services
if [ $? -ne 0 ]; then exit 1; fi

# 4. Setup Frontend
setup_frontend

# 5. Configure and Run Caddy (with SSL check)
setup_caddy
if [ $? -ne 0 ]; then 
    echo -e "${RED}Installation of Web Panel Failed. Please fix the issue and re-run.${NC}"
    exit 1 
fi

# 6. Finalize and create menu
create_panel_menu

whiptail --msgbox "Web Panel Installation Complete!\n\nAccess URL:\nhttps://${PANEL_USER_DOMAIN}/$RANDOM_PATH\n\nTo manage the Web Panel, run: nodepanel" 15 70 --title "Installation Success"
