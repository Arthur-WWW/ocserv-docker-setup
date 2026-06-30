# Modern ocserv Docker Setup

This project provides a highly optimized, fully containerized deployment of the **OpenConnect VPN Server (ocserv)**. 
Built using a modern Docker multi-stage architecture, it completely isolates the VPN environment from the host system while ensuring you always run the latest official version with strict security standards.

## ✨ Key Features

- **Extreme Lightness & Security**: Uses `alpine:latest` and compiles `ocserv 1.5.0` (or newer) directly from official sources. The final image size is drastically minimized by stripping build dependencies.
- **Smart Certificate Management**:
  - Automatically provisions and renews **Let's Encrypt** certificates if a domain is provided (via bundled `acme.sh`).
  - Gracefully falls back to generating secure **Self-Signed Certificates** if no domain is used.
- **Robust Mobile & Network Compatibility**:
  - Full support for **Cisco AnyConnect** and **OpenConnect** clients.
  - Implements **Strict TLS Priorities** to prevent fallback to slow, legacy ciphers (resolves common connection stalls).
  - Includes **MTU Discovery** and tuned **Dead Peer Detection (DPD)** to prevent disconnects on mobile devices during network handover.
  - Uses a conflict-free default subnet (`192.168.211.0/24`) to avoid routing issues with home/corporate WiFi networks.
- **Secure Architecture**: Drops privileged mode. Requires only `NET_ADMIN` capability and safely handles `iptables` NAT forwarding internally.

---

## 🚀 Getting Started

### Prerequisites
- Docker & Docker Compose installed on your server.
- TCP/UDP port `443` open in your firewall.
- *(Optional)* TCP port `80` open if you plan to use Let's Encrypt auto-certificates.

### 1. Clone the Repository
```bash
git clone https://github.com/Arthur-WWW/ocserv-docker-setup.git
cd ocserv-docker-setup
```

### 2. Configure (Optional)
If you have a domain name pointing to your server's IP and wish to use valid Let's Encrypt certificates:
1. Open `docker-compose.yml`.
2. Uncomment the `DOMAIN` environment variable and set it to your domain (e.g., `DOMAIN=vpn.example.com`).

*If you skip this step, the server will automatically generate self-signed certificates on its first run.*

### 3. Build & Run
Start the service in the background. The initial run will download the official ocserv source code and compile it locally.
```bash
docker-compose up -d --build
```

### 4. Manage Users
A convenient helper script `manage-user.sh` is provided to manage VPN credentials without needing to manually enter the container.

```bash
# Add a new VPN user (will prompt for a password)
./manage-user.sh add my_username

# List all current users
./manage-user.sh list

# Delete a VPN user
./manage-user.sh delete my_username

# Temporarily lock/unlock a user
./manage-user.sh lock my_username
./manage-user.sh unlock my_username
```

---

## 🔌 Connecting to the VPN

Download the official client for your platform:
- **Windows / macOS / Linux**: [Cisco AnyConnect Secure Mobility Client](https://www.cisco.com/) or [OpenConnect GUI](https://openconnect.github.io/openconnect-gui/)
- **iOS / Android**: Search for `Cisco Secure Client` or `AnyConnect` in the App Store / Google Play.

1. Open the client and add a new connection.
2. Enter your Server IP address or Domain Name.
3. If using self-signed certificates (no domain configured), you will receive an "Untrusted Server" warning. Accept/Continue anyway.
4. Enter the username and password you created via the `manage-user.sh` script.
5. You are now securely connected to the VPN! (Default is Full Tunnel: all traffic routes through the server).

## 🛠 Advanced Configuration

All core configurations are exposed via the `config/` directory after the first run.
- **`config/ocserv.conf`**: The main VPN settings (Subnets, DNS, Routing, TLS configs). The service requires a restart (`docker-compose restart`) to apply changes.
- **`certs/`**: The directory where your certificates are stored. You can drop your own valid `server-cert.pem` and `server-key.pem` here manually if you prefer not to use the bundled `acme.sh` logic.