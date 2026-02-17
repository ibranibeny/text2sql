#!/usr/bin/env bash
# =============================================================================
# setup_vm.sh — VM Configuration Script (runs ON the VM via SSH)
# =============================================================================
#
# This script is copied to the VM by deploy.sh and executed remotely.
# It installs all dependencies, seeds the database, and starts Streamlit.
#
# =============================================================================

set -euo pipefail

echo "============================================================"
echo "  Text-to-SQL Workshop — VM Setup"
echo "============================================================"

APP_DIR="/home/$(whoami)/text2sql"

# -----------------------------------------------------------
# 1. System packages
# -----------------------------------------------------------
echo "[1/7] Updating system packages..."
sudo apt-get update -qq

# Install software-properties-common for add-apt-repository, and lsb-release
sudo apt-get install -y -qq \
    software-properties-common \
    lsb-release \
    curl \
    gnupg2 \
    unixodbc \
    unixodbc-dev \
    > /dev/null 2>&1

# Add deadsnakes PPA for python3.11 (minimal image may not have it)
sudo add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1
sudo apt-get update -qq
sudo apt-get install -y -qq \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    > /dev/null 2>&1
echo "  ✓ System packages installed."

# -----------------------------------------------------------
# 2. Microsoft ODBC Driver 18
# -----------------------------------------------------------
echo "[2/7] Installing ODBC Driver 18 for SQL Server..."
if ! dpkg -s msodbcsql18 &> /dev/null; then
    # Import Microsoft GPG key (--yes to overwrite if exists)
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        sudo gpg --yes --dearmor -o /usr/share/keyrings/microsoft-prod.gpg

    # Detect Ubuntu version from /etc/os-release (works on minimal images)
    UBUNTU_VERSION=$(. /etc/os-release && echo "$VERSION_ID")
    UBUNTU_CODENAME=$(. /etc/os-release && echo "$UBUNTU_CODENAME")
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/${UBUNTU_VERSION}/prod ${UBUNTU_CODENAME} main" | \
        sudo tee /etc/apt/sources.list.d/mssql-release.list > /dev/null

    sudo apt-get update -qq
    sudo ACCEPT_EULA=Y apt-get install -y -qq msodbcsql18 > /dev/null 2>&1
    echo "  ✓ ODBC Driver 18 installed."
else
    echo "  ✓ ODBC Driver 18 already installed."
fi

# -----------------------------------------------------------
# 3. Application directory
# -----------------------------------------------------------
echo "[3/7] Setting up application directory..."
mkdir -p "$APP_DIR"
cp /tmp/agent.py "$APP_DIR/"
cp /tmp/app.py "$APP_DIR/"
cp /tmp/text2sql_env "$APP_DIR/.env"
cp /tmp/seed_data.sql "$APP_DIR/"
echo "  ✓ Application files copied to $APP_DIR"

# -----------------------------------------------------------
# 4. Python virtual environment
# -----------------------------------------------------------
echo "[4/7] Creating Python virtual environment..."
cd "$APP_DIR"
python3.11 -m venv venv
source venv/bin/activate

pip install --upgrade pip -q
pip install -q \
    streamlit \
    openai \
    pyodbc \
    python-dotenv \
    pandas \
    azure-identity
echo "  ✓ Python packages installed."

# -----------------------------------------------------------
# 5. Seed the database
# -----------------------------------------------------------
echo "[5/7] Seeding the database..."

# Load .env variables safely (handles values with braces/spaces)
while IFS='=' read -r key value; do
    # Skip comments and blank lines
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    # Strip surrounding quotes from value
    value="${value#\"}"
    value="${value%\"}"
    export "$key=$value"
done < "$APP_DIR/.env"

# Install sqlcmd if not present
if ! command -v sqlcmd &> /dev/null; then
    sudo ACCEPT_EULA=Y apt-get install -y -qq mssql-tools18 > /dev/null 2>&1
    export PATH="$PATH:/opt/mssql-tools18/bin"
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
fi

# Execute seed script (strip Windows line endings first)
sed -i 's/\r$//' "$APP_DIR/seed_data.sql"
/opt/mssql-tools18/bin/sqlcmd \
    -S "$SQL_SERVER" \
    -d "$SQL_DATABASE" \
    -U "$SQL_USERNAME" \
    -P "$SQL_PASSWORD" \
    -i "$APP_DIR/seed_data.sql" \
    -C \
    || echo "  ⚠ Warning: seed_data.sql may have encountered issues"

echo "  ✓ Database seeded."

# -----------------------------------------------------------
# 6. Add swap space (prevents OOM kills on Standard_B2s)
# -----------------------------------------------------------
echo "[6/8] Adding swap space..."
if ! swapon --show | grep -q /swapfile; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    echo "  ✓ 2GB swap created and activated."
else
    echo "  ✓ Swap already active."
fi

# -----------------------------------------------------------
# 7. Systemd service for Streamlit (hardened)
# -----------------------------------------------------------
echo "[7/8] Creating systemd service for Streamlit..."

sudo tee /etc/systemd/system/text2sql.service > /dev/null <<EOF
[Unit]
Description=Text-to-SQL Streamlit Application
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
Environment=PATH=$APP_DIR/venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$APP_DIR/venv/bin/streamlit run app.py --server.port=8501 --server.headless=true --server.address=0.0.0.0
Restart=always
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=10
MemoryMax=1G
OOMPolicy=continue
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable text2sql.service
echo "  ✓ Systemd service created (hardened with auto-restart + OOM protection)."

# -----------------------------------------------------------
# 8. Start the application
# -----------------------------------------------------------
echo "[8/8] Starting Streamlit application..."
sudo systemctl start text2sql.service

# Wait a moment and check status
sleep 3
if sudo systemctl is-active --quiet text2sql.service; then
    echo "  ✓ Streamlit is running on port 8501."
else
    echo "  ⚠ Service may not have started. Check: sudo journalctl -u text2sql -f"
fi

echo ""
echo "============================================================"
echo "  VM Setup Complete!"
echo "  App URL: http://$(curl -s ifconfig.me):8501"
echo "============================================================"
