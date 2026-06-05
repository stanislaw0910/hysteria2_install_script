#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print messages
print_msg() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (sudo)"
    exit 1
fi

# Get external IP
print_msg "Determining external IP address..."
EXTERNAL_IP=$(curl -s https://api.ipify.org)
if [[ -z "$EXTERNAL_IP" ]]; then
    print_error "Failed to determine external IP address"
    exit 1
fi
print_msg "External IP: $EXTERNAL_IP"

# Function to get domain name via reverse DNS lookup
get_domain_by_reverse_dns() {
    local ip=$1
    local domain=""
    
    # Method 1: Using dig (recommended)
    if command -v dig &> /dev/null; then
        print_msg "Attempting to get domain via dig..."
        domain=$(dig -x "$ip" +short | head -1)
        if [[ -n "$domain" && "$domain" != *".in-addr.arpa."* ]]; then
            # Remove trailing dot from domain
            domain="${domain%.}"
            echo "$domain"
            return 0
        fi
    fi
    
    # Method 2: Using host
    if command -v host &> /dev/null; then
        print_msg "Attempting to get domain via host..."
        domain=$(host "$ip" | grep "domain name pointer" | head -1 | awk '{print $NF}' | sed 's/\.$//')
        if [[ -n "$domain" ]]; then
            echo "$domain"
            return 0
        fi
    fi
    
    # Method 3: Using nslookup
    if command -v nslookup &> /dev/null; then
        print_msg "Attempting to get domain via nslookup..."
        domain=$(nslookup "$ip" | grep "name =" | head -1 | awk '{print $NF}' | sed 's/\.$//')
        if [[ -n "$domain" ]]; then
            echo "$domain"
            return 0
        fi
    fi
    
    # If domain cannot be obtained
    return 1
}

# Get domain name
print_msg "Performing reverse DNS lookup for IP: $EXTERNAL_IP"
DOMAIN_NAME=$(get_domain_by_reverse_dns "$EXTERNAL_IP")

# If reverse DNS gave no result, try other methods
if [[ -z "$DOMAIN_NAME" ]]; then
    print_warning "Reverse DNS lookup returned no result for IP $EXTERNAL_IP"
    
    # Method 4: Check system hostname
    print_msg "Checking system hostname..."
    SYSTEM_HOSTNAME=$(hostname -f 2>/dev/null)
    if [[ -n "$SYSTEM_HOSTNAME" && "$SYSTEM_HOSTNAME" != "localhost" && "$SYSTEM_HOSTNAME" != *".localdomain" ]]; then
        DOMAIN_NAME="$SYSTEM_HOSTNAME"
        print_msg "Using system hostname: $DOMAIN_NAME"
    else
        # Method 5: Check environment variables or config files
        if [[ -f /etc/hostname ]]; then
            HOSTNAME_FILE=$(cat /etc/hostname | tr -d '\n')
            if [[ -n "$HOSTNAME_FILE" && "$HOSTNAME_FILE" != "localhost" ]]; then
                DOMAIN_NAME="$HOSTNAME_FILE"
                print_msg "Using hostname from /etc/hostname: $DOMAIN_NAME"
            fi
        fi
    fi
fi

# If all methods fail, use nip.io
if [[ -z "$DOMAIN_NAME" ]]; then
    print_warning "Could not determine domain name automatically"
    DOMAIN_NAME="${EXTERNAL_IP}.nip.io"
    print_msg "Will use automatic domain: $DOMAIN_NAME"
    print_msg "For production, it is recommended to configure a real domain"
fi

print_success "Determined domain name: $DOMAIN_NAME"

# User confirmation
read -p "Use domain '$DOMAIN_NAME'? (y/n, default y): " CONFIRM
if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
    read -p "Enter domain name manually: " MANUAL_DOMAIN
    if [[ -n "$MANUAL_DOMAIN" ]]; then
        DOMAIN_NAME="$MANUAL_DOMAIN"
        print_msg "Using manually entered domain: $DOMAIN_NAME"
    else
        print_error "Domain name cannot be empty"
        exit 1
    fi
fi

# Install qrencode for QR code generation
print_msg "Installing qrencode for QR code generation..."
apt-get update -qq
apt-get install qrencode -y -qq

if [[ $? -ne 0 ]]; then
    print_warning "Failed to install qrencode via apt, trying apt-get..."
    apt-get update
    apt-get install qrencode -y
fi

if command -v qrencode &> /dev/null; then
    print_success "qrencode successfully installed"
else
    print_warning "qrencode not installed, QR code will not be created"
fi

# Install Hysteria
print_msg "Installing Hysteria..."
bash <(curl -fsSL https://get.hy2.sh/)

if [[ $? -ne 0 ]]; then
    print_error "Error installing Hysteria"
    exit 1
fi

# Backup existing config
print_msg "Creating configuration backup..."
if [[ -f /etc/hysteria/config.yaml ]]; then
    cp /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak
    print_msg "Backup created: /etc/hysteria/config.yaml.bak"
else
    print_warning "Configuration file not found, backup not created"
fi

# Remove old config
print_msg "Removing old configuration file..."
rm -f /etc/hysteria/config.yaml

# Create masquerade directory
print_msg "Creating masquerade directory..."
mkdir -p /var/www/masq

# Create HTML file
print_msg "Creating HTML file for masquerade..."
tee /var/www/masq/index.html >/dev/null <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Please wait</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.dots{display:flex;gap:15px;margin-bottom:30px}.d{width:20px;height:20px;background:#fff;border-radius:50%;animation:b 1.4s infinite ease-in-out both}.d:nth-child(1){animation-delay:-0.32s}.d:nth-child(2){animation-delay:-0.16s}@keyframes b{0%,80%,100%{transform:scale(0);opacity:0.2}40%{transform:scale(1);opacity:1}}.t{color:#555;font-size:14px;letter-spacing:2px;font-weight:600}</style></head><body><div class="dots"><div class="d"></div><div class="d"></div><div class="d"></div></div><div class="t">RETRYING CONNECTION</div></body></html>
HTML

print_msg "HTML file successfully created"

# Create configuration file
print_msg "Creating Hysteria configuration..."
cat > /etc/hysteria/config.yaml <<EOF
listen: :8443

acme:
  domains:
    - $DOMAIN_NAME
  email: itnewage777@gmail.com

auth:
  type: userpass
  userpass:
    D: Srvdelta12!

masquerade:
  type: file
  file:
    dir: /var/www/masq
  listenHTTP: :80
  listenHTTPS: :443
  forceHTTPS: true
EOF

if [[ $? -ne 0 ]]; then
    print_error "Error creating configuration file"
    exit 1
fi

print_msg "Configuration file created: /etc/hysteria/config.yaml"

# Restart service
print_msg "Restarting Hysteria service..."
systemctl restart hysteria-server.service

if [[ $? -ne 0 ]]; then
    print_error "Error restarting service"
    print_warning "Check status: systemctl status hysteria-server.service"
    exit 1
fi

# Enable autostart
print_msg "Enabling Hysteria autostart..."
systemctl enable hysteria-server.service

if [[ $? -ne 0 ]]; then
    print_error "Error enabling autostart"
    exit 1
fi

# Check status
print_msg "Checking service status..."
systemctl status hysteria-server.service --no-pager

# Generate connection string in new format with URL encoding
print_msg "Generating connection string..."

# Connection parameters
PROTOCOL="hysteria2"
USERNAME="D"
PASSWORD="Srvdelta12"
PORT="8443"
SERVER="$DOMAIN_NAME"

# URL-encode special characters
# : = %3A
# ! = %21
ENCODED_CREDENTIALS="${USERNAME}%3A${PASSWORD}%21"

# Create connection string in new format with parameters
CONNECTION_STRING="${PROTOCOL}://${ENCODED_CREDENTIALS}@${SERVER}:${PORT}/?insecure=0&sni=${SERVER}#Hysteria2_${SERVER//./_}"

# Alternative format for clients (more readable)
CONNECTION_INFO="===========================================
HYSTERIA2 CONNECTION INFORMATION
===========================================
Server: ${SERVER}
Port: ${PORT}
Protocol: ${PROTOCOL}
Username: ${USERNAME}
Password: ${PASSWORD}
External IP: ${EXTERNAL_IP}

Connection URI (with escaped characters):
${CONNECTION_STRING}

Example for client config file:
-------------------------------------------
server: ${SERVER}:${PORT}
auth: ${USERNAME}:${PASSWORD}
tls:
  sni: ${SERVER}
  insecure: false
-------------------------------------------

For mobile clients, use the URI string above.
==========================================="

# Save connection string to file
OUTPUT_FILE="/root/hysteria_connection_info.txt"
echo "$CONNECTION_INFO" > "$OUTPUT_FILE"

if [[ -f "$OUTPUT_FILE" ]]; then
    print_success "Connection information saved to file: $OUTPUT_FILE"
    print_msg "File contents:"
    echo "----------------------------------------"
    cat "$OUTPUT_FILE"
    echo "----------------------------------------"
else
    print_error "Failed to save connection information file"
fi

# Additionally save only URI string to a separate file
URI_FILE="/root/h2_uri.txt"
echo "$CONNECTION_STRING" > "$URI_FILE"
print_success "URI string saved to: $URI_FILE"

# Create QR code for easy import
if command -v qrencode &> /dev/null; then
    print_msg "Creating QR code..."
    QR_FILE="/root/h2.png"
    
    # Create QR code with improved parameters for better scanning
    # -s 6: dot size 6 pixels
    # -l H: high error correction level (30%)
    # -m 2: margin of 2 modules
    qrencode -o "$QR_FILE" -s 6 -l H -m 2 "$CONNECTION_STRING"
    
    if [[ $? -eq 0 && -f "$QR_FILE" ]]; then
        print_success "QR code saved to: $QR_FILE"
        print_msg "QR code size: $(du -h "$QR_FILE" | cut -f1)"
        
        # Additionally create QR code in text format for terminal output
        print_msg "QR code in text format:"
        echo "----------------------------------------"
        qrencode -t UTF8 -l H -m 1 "$CONNECTION_STRING" 2>/dev/null || print_warning "Failed to display QR code in terminal"
        echo "----------------------------------------"
    else
        print_error "Failed to create QR code"
    fi
else
    print_warning "qrencode not installed, QR code will not be created"
    print_msg "Install qrencode manually: apt install qrencode -y"
fi

print_msg "========================================="
print_msg "Installation completed successfully!"
print_msg "========================================="
print_msg "External IP: $EXTERNAL_IP"
print_msg "Domain: $DOMAIN_NAME"
print_msg "Port: 8443"
print_msg "Username: $USERNAME"
print_msg "Password: $PASSWORD"
print_msg ""
print_msg "Connection URI:"
print_msg "$CONNECTION_STRING"
print_msg ""
print_msg "Files with connection information:"
print_msg "  • Full information: $OUTPUT_FILE"
print_msg "  • Only URI: $URI_FILE"
if [[ -f "/root/h2.png" ]]; then
    print_msg "  • QR code: /root/h2.png"
fi
print_msg ""
print_msg "To view connection information, run:"
print_msg "  cat $OUTPUT_FILE"
print_msg ""
print_msg "Check service status: systemctl status hysteria-server.service"
print_msg "View logs: journalctl -u hysteria-server.service -f"
print_msg "========================================="
