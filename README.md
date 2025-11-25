# 🚀 Blitz Node - Hysteria2 Server Setup  ✨ **Complete Hysteria2 node installation** with Panel integration, Authentication, and Traffic Tracking. Featuring an **Interactive TUI Setup** and a dedicated **Management Menu**.

---

## 🌟 Prerequisites

| Component | Requirement | Note |
| :---: | :---: | :--- |
| **Operating System** | 🟢 Ubuntu Server **22.04+** | |
| **User Access** | 👑 Root Access | |

---

## 📦 Installation Steps

### 1. Run Installer
Clone the repository and make the installer executable:

```bash
git clone https://github.com/ReturnFI/Blitz-Node.git
cd Blitz-Node
chmod +x install.sh
```

Execute the installer, providing default values for the port and SNI:

```bash
./install.sh install <port> <sni>
```

**Example:**

```bash
./install.sh install 443 panel.example.com
```

### 2. Interactive TUI Setup
The installer will switch to a **Text-based User Interface (TUI)** for final configuration.

---

## ⚙️ Post-Installation Management (nodehys2 Menu)

Once installed, run the following command for node management:

```bash
nodehys2
```

### Management Menu Options:

| Option | Command | Description |
| :---: | :--- | :--- |
| **1** | Full Node Service Management | Control 🟢 **Start**, 🔴 **Stop**, 🔄 **Restart**, 📊 **Status**, and view 📜 **Logs** for all Hysteria2 services. |
| **2** | Install Node Management Web Panel | **🚧 Under Development:** Future option to deploy a local web administration panel (FastAPI + Caddy). |
| **3** | Exit Menu | 🚪 Closes the menu application. |

---

## 🗑️ Uninstall

To completely and cleanly remove the Blitz Node installation:

```bash
bash install.sh uninstall
```

This command safely stops and removes all services, the Hysteria2 binary, the dedicated `hysteria` user, and the entire configuration directory (`/etc/hysteria`).
