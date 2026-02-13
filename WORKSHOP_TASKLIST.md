# Workshop: Agentic AI — Natural Language to SQL with Microsoft Foundry

## Document Metadata

| Field | Value |
|---|---|
| **Title** | Agentic AI Text-to-SQL Workshop — Task List & Implementation Guide |
| **Version** | 1.0 |
| **Date** | 12 February 2026 |
| **Author** | Workshop Facilitator |
| **Scope** | End-to-end deployment of an Agentic AI Text-to-SQL solution on Azure |
| **Tooling** | Azure CLI (`az`), Python, Streamlit, Microsoft Foundry SDK |

---

## 1. Solution Architecture

```
┌──────────────┐     HTTPS      ┌─────────────────────────────┐
│              │ ──────────────► │  Azure VM (Indonesia Central)│
│  End User    │                 │  Streamlit Frontend          │
│  (Browser)   │ ◄────────────── │  Port 8501                  │
└──────────────┘     Response    └──────────┬──────────────────┘
                                            │  REST / SDK
                                            ▼
                                 ┌─────────────────────────────┐
                                 │  Microsoft Foundry           │
                                 │  (AI Foundry Agent Service)  │
                                 │  GPT-4o Model Deployment     │
                                 │  ─────────────────────────── │
                                 │  Agent: Text-to-SQL          │
                                 │  System Prompt + Tools       │
                                 └──────────┬──────────────────┘
                                            │  Generated SQL
                                            ▼
                                 ┌─────────────────────────────┐
                                 │  Azure SQL Database          │
                                 │  (Logical Server)            │
                                 │  Sample: Sales / Inventory   │
                                 └──────────┬──────────────────┘
                                            │  Query Results
                                            ▼
                                 ┌─────────────────────────────┐
                                 │  Microsoft Foundry           │
                                 │  LLM generates natural-      │
                                 │  language answer from results │
                                 └──────────┬──────────────────┘
                                            │  Final Answer
                                            ▼
                                 ┌─────────────────────────────┐
                                 │  Streamlit Frontend (VM)     │
                                 │  Displays answer to user     │
                                 └─────────────────────────────┘
```

### Data Flow Summary

1. **User Prompt** → Streamlit UI on Azure VM (Indonesia Central)
2. **Streamlit App** → Calls Microsoft Foundry Agent Service API
3. **AI Agent** → Interprets natural language, generates SQL query
4. **SQL Execution** → Agent executes query against Azure SQL Database
5. **Result Retrieval** → Raw query results returned to Agent
6. **LLM Synthesis** → Agent generates human-readable answer from results
7. **Response** → Final answer rendered in Streamlit UI

---

## 2. Prerequisites & Assumptions

| # | Prerequisite | Notes |
|---|---|---|
| 1 | Active Azure Subscription | Contributor or Owner role required |
| 2 | Azure CLI ≥ 2.60 installed locally | `az --version` to verify |
| 3 | Python ≥ 3.10 installed locally | For local development and testing |
| 4 | SSH client available | For VM remote access |
| 5 | Microsoft Foundry access | Portal: https://ai.azure.com |
| 6 | Sufficient quota for GPT-4o | In a supported region (e.g., East US, Sweden Central) |

> **Important**: As of this writing, Microsoft Foundry Agent Service model deployments may not be available in `indonesiacentral`. The **VM (frontend)** will be deployed in Indonesia Central for low-latency user access, while the **AI Foundry resource** will reside in a supported region (e.g., `eastus` or `swedencentral`). Azure SQL Database will be co-located with the AI Foundry resource or placed in `indonesiacentral` depending on availability.

---

## 3. Task List

### Phase 1 — Azure Environment Setup

#### Task 1.1: Authenticate and Set Subscription

**Objective**: Establish an authenticated Azure CLI session and configure the target subscription.

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"
az account show
```

**Official Documentation**:
- [Sign in with Azure CLI](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli)
- [Manage Azure subscriptions with Azure CLI](https://learn.microsoft.com/en-us/cli/azure/manage-azure-subscriptions-azure-cli)

---

#### Task 1.2: Create Resource Group

**Objective**: Provision a resource group in the Indonesia Central region to host the VM and related resources.

```bash
# Variables
export RG_NAME="rg-text2sql-workshop"
export LOCATION_VM="indonesiacentral"

az group create \
    --name $RG_NAME \
    --location $LOCATION_VM \
    --tags project=text2sql-workshop environment=dev
```

**Official Documentation**:
- [az group create](https://learn.microsoft.com/en-us/cli/azure/group#az-group-create)

---

#### Task 1.3: Create Resource Group for AI Foundry (if separate region required)

**Objective**: Provision a resource group in a region that supports Microsoft Foundry Agent Service and GPT-4o.

```bash
export RG_AI_NAME="rg-text2sql-ai"
export LOCATION_AI="eastus"   # Adjust based on Foundry availability

az group create \
    --name $RG_AI_NAME \
    --location $LOCATION_AI \
    --tags project=text2sql-workshop environment=dev
```

---

### Phase 2 — Azure SQL Database Provisioning & Dummy Data

#### Task 2.1: Create Azure SQL Logical Server

**Objective**: Deploy an Azure SQL logical server instance.

```bash
export SQL_SERVER_NAME="sql-text2sql-workshop"
export SQL_ADMIN_USER="sqladmin"
export SQL_ADMIN_PASSWORD="<STRONG_PASSWORD_HERE>"   # Min 8 chars, complex

az sql server create \
    --name $SQL_SERVER_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION_VM \
    --admin-user $SQL_ADMIN_USER \
    --admin-password $SQL_ADMIN_PASSWORD
```

> **Note**: If `indonesiacentral` does not support Azure SQL, use `$LOCATION_AI` (eastus) and `$RG_AI_NAME` instead.

**Official Documentation**:
- [az sql server create](https://learn.microsoft.com/en-us/cli/azure/sql/server#az-sql-server-create)
- [Create a single database — Azure CLI](https://learn.microsoft.com/en-us/azure/azure-sql/database/scripts/create-and-configure-database-cli)

---

#### Task 2.2: Configure Firewall Rules

**Objective**: Allow Azure services and local development machine to connect to the SQL server.

```bash
# Allow Azure services
az sql server firewall-rule create \
    --resource-group $RG_NAME \
    --server $SQL_SERVER_NAME \
    --name AllowAzureServices \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 0.0.0.0

# Allow your local IP (replace with your IP)
export MY_IP=$(curl -s https://api.ipify.org)
az sql server firewall-rule create \
    --resource-group $RG_NAME \
    --server $SQL_SERVER_NAME \
    --name AllowMyIP \
    --start-ip-address $MY_IP \
    --end-ip-address $MY_IP
```

**Official Documentation**:
- [az sql server firewall-rule create](https://learn.microsoft.com/en-us/cli/azure/sql/server/firewall-rule#az-sql-server-firewall-rule-create)

---

#### Task 2.3: Create Azure SQL Database

**Objective**: Create the application database that will store the sample data.

```bash
export SQL_DB_NAME="SalesDB"

az sql db create \
    --resource-group $RG_NAME \
    --server $SQL_SERVER_NAME \
    --name $SQL_DB_NAME \
    --edition GeneralPurpose \
    --family Gen5 \
    --capacity 2 \
    --max-size 2GB
```

**Official Documentation**:
- [az sql db create](https://learn.microsoft.com/en-us/cli/azure/sql/db#az-sql-db-create)

---

#### Task 2.4: Populate Database with Dummy Data

**Objective**: Create sample tables and insert representative data for the Text-to-SQL demonstration.

Execute against the SQL database using `sqlcmd` or any SQL client:

```sql
-- ==============================================
-- Schema: Sales demonstration dataset
-- ==============================================

CREATE TABLE Customers (
    CustomerID    INT PRIMARY KEY IDENTITY(1,1),
    FirstName     NVARCHAR(50)   NOT NULL,
    LastName      NVARCHAR(50)   NOT NULL,
    Email         NVARCHAR(100),
    City          NVARCHAR(50),
    Country       NVARCHAR(50),
    CreatedDate   DATE DEFAULT GETDATE()
);

CREATE TABLE Products (
    ProductID     INT PRIMARY KEY IDENTITY(1,1),
    ProductName   NVARCHAR(100)  NOT NULL,
    Category      NVARCHAR(50),
    Price         DECIMAL(10,2)  NOT NULL,
    StockQuantity INT            DEFAULT 0
);

CREATE TABLE Orders (
    OrderID       INT PRIMARY KEY IDENTITY(1,1),
    CustomerID    INT            NOT NULL REFERENCES Customers(CustomerID),
    OrderDate     DATE           NOT NULL DEFAULT GETDATE(),
    TotalAmount   DECIMAL(10,2),
    Status        NVARCHAR(20)   DEFAULT 'Pending'
);

CREATE TABLE OrderItems (
    OrderItemID   INT PRIMARY KEY IDENTITY(1,1),
    OrderID       INT            NOT NULL REFERENCES Orders(OrderID),
    ProductID     INT            NOT NULL REFERENCES Products(ProductID),
    Quantity      INT            NOT NULL,
    UnitPrice     DECIMAL(10,2)  NOT NULL
);

-- Insert sample customers
INSERT INTO Customers (FirstName, LastName, Email, City, Country) VALUES
('Budi',    'Santoso',   'budi.santoso@example.com',    'Jakarta',   'Indonesia'),
('Siti',    'Rahayu',    'siti.rahayu@example.com',     'Surabaya',  'Indonesia'),
('Ahmad',   'Wijaya',    'ahmad.wijaya@example.com',    'Bandung',   'Indonesia'),
('Dewi',    'Lestari',   'dewi.lestari@example.com',    'Yogyakarta','Indonesia'),
('Rizky',   'Pratama',   'rizky.pratama@example.com',   'Medan',     'Indonesia'),
('Maria',   'Gonzalez',  'maria.gonzalez@example.com',  'Singapore', 'Singapore'),
('Tanaka',  'Hiroshi',   'tanaka.h@example.com',        'Tokyo',     'Japan'),
('Sarah',   'Johnson',   'sarah.j@example.com',         'Sydney',    'Australia'),
('Wei',     'Chen',      'wei.chen@example.com',        'Kuala Lumpur','Malaysia'),
('Pham',    'Minh',      'pham.minh@example.com',       'Ho Chi Minh','Vietnam');

-- Insert sample products
INSERT INTO Products (ProductName, Category, Price, StockQuantity) VALUES
('Laptop Pro 15',       'Electronics',  1299.99, 50),
('Wireless Mouse',      'Electronics',  29.99,   200),
('USB-C Hub',           'Accessories',  49.99,   150),
('Mechanical Keyboard', 'Electronics',  89.99,   100),
('Monitor 27 inch',     'Electronics',  399.99,  75),
('Webcam HD',           'Electronics',  59.99,   120),
('Laptop Stand',        'Accessories',  39.99,   180),
('Noise Cancelling Headphones', 'Electronics', 199.99, 90),
('External SSD 1TB',    'Storage',      109.99,  130),
('Desk Lamp LED',       'Office',       24.99,   250);

-- Insert sample orders
INSERT INTO Orders (CustomerID, OrderDate, TotalAmount, Status) VALUES
(1, '2025-12-01', 1379.97, 'Completed'),
(2, '2025-12-03', 89.99,   'Completed'),
(3, '2025-12-05', 509.98,  'Shipped'),
(1, '2025-12-10', 259.98,  'Completed'),
(4, '2025-12-12', 1299.99, 'Pending'),
(5, '2025-12-15', 149.97,  'Completed'),
(6, '2025-12-18', 399.99,  'Shipped'),
(7, '2025-12-20', 89.99,   'Completed'),
(8, '2025-12-22', 239.98,  'Pending'),
(9, '2026-01-05', 109.99,  'Completed'),
(10,'2026-01-10', 1499.98, 'Shipped'),
(2, '2026-01-15', 59.99,   'Completed'),
(3, '2026-01-20', 329.97,  'Pending');

-- Insert sample order items
INSERT INTO OrderItems (OrderID, ProductID, Quantity, UnitPrice) VALUES
(1, 1, 1, 1299.99),
(1, 2, 1, 29.99),
(1, 3, 1, 49.99),
(2, 4, 1, 89.99),
(3, 5, 1, 399.99),
(3, 9, 1, 109.99),
(4, 8, 1, 199.99),
(4, 6, 1, 59.99),
(5, 1, 1, 1299.99),
(6, 2, 2, 29.99),
(6, 4, 1, 89.99),
(7, 5, 1, 399.99),
(8, 4, 1, 89.99),
(9, 8, 1, 199.99),
(9, 7, 1, 39.99),
(10, 9, 1, 109.99),
(11, 1, 1, 1299.99),
(11, 8, 1, 199.99),
(12, 6, 1, 59.99),
(13, 3, 3, 49.99),
(13, 10, 3, 24.99),
(13, 7, 2, 39.99);
```

**Official Documentation**:
- [Connect and query Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/connect-query-ssms)
- [sqlcmd utility](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility)

---

### Phase 2B — Azure SQL Database (Option B: Private Endpoint — No Firewall)

> **Selection Guidance**: Choose **Phase 2 (Option A)** above if you prefer a simpler setup using public endpoint with firewall rules. Choose **Phase 2B (Option B)** below if you require a more secure, production-grade configuration that eliminates public internet exposure to the SQL server via Azure Private Endpoint. **Do not execute both — choose one.**

#### Task 2B.1: Create Azure SQL Logical Server with Public Access Disabled

**Objective**: Deploy an Azure SQL logical server with public network access explicitly disabled.

```bash
export SQL_SERVER_NAME="sql-text2sql-workshop"
export SQL_ADMIN_USER="sqladmin"
export SQL_ADMIN_PASSWORD="<STRONG_PASSWORD_HERE>"   # Min 8 chars, complex

az sql server create \
    --name $SQL_SERVER_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION_VM \
    --admin-user $SQL_ADMIN_USER \
    --admin-password $SQL_ADMIN_PASSWORD \
    --enable-public-network false
```

> **Note**: With `--enable-public-network false`, no firewall rules are needed. All connectivity is routed through the Azure private backbone via Private Endpoint.

**Official Documentation**:
- [az sql server create](https://learn.microsoft.com/en-us/cli/azure/sql/server#az-sql-server-create)
- [Azure SQL Database — Deny public network access](https://learn.microsoft.com/en-us/azure/azure-sql/database/connectivity-settings-how-to#deny-public-network-access)

---

#### Task 2B.2: Create Azure SQL Database

**Objective**: Create the application database (identical to Option A).

```bash
export SQL_DB_NAME="SalesDB"

az sql db create \
    --resource-group $RG_NAME \
    --server $SQL_SERVER_NAME \
    --name $SQL_DB_NAME \
    --edition GeneralPurpose \
    --family Gen5 \
    --capacity 2 \
    --max-size 2GB
```

---

#### Task 2B.3: Create Virtual Network and Subnet for VM

**Objective**: Create a VNet with two subnets — one for the VM and one dedicated to Private Endpoints.

```bash
export VNET_NAME="vnet-text2sql"
export SUBNET_VM="subnet-vm"
export SUBNET_PE="subnet-privateendpoint"

# Create VNet with VM subnet
az network vnet create \
    --resource-group $RG_NAME \
    --name $VNET_NAME \
    --location $LOCATION_VM \
    --address-prefix 10.0.0.0/16 \
    --subnet-name $SUBNET_VM \
    --subnet-prefix 10.0.1.0/24

# Create subnet for Private Endpoints (disable private endpoint network policies)
az network vnet subnet create \
    --resource-group $RG_NAME \
    --vnet-name $VNET_NAME \
    --name $SUBNET_PE \
    --address-prefix 10.0.2.0/24 \
    --disable-private-endpoint-network-policies true
```

**Official Documentation**:
- [az network vnet create](https://learn.microsoft.com/en-us/cli/azure/network/vnet#az-network-vnet-create)
- [Disable private endpoint network policies](https://learn.microsoft.com/en-us/azure/private-link/disable-private-endpoint-network-policy)

---

#### Task 2B.4: Create Private Endpoint for Azure SQL

**Objective**: Establish a Private Endpoint that maps the SQL Server's private IP into the VNet, eliminating the need for firewall rules.

```bash
export PE_NAME="pe-sql-text2sql"

# Get SQL Server resource ID
export SQL_SERVER_ID=$(az sql server show \
    --name $SQL_SERVER_NAME \
    --resource-group $RG_NAME \
    --query id -o tsv)

# Create Private Endpoint
az network private-endpoint create \
    --resource-group $RG_NAME \
    --name $PE_NAME \
    --location $LOCATION_VM \
    --vnet-name $VNET_NAME \
    --subnet $SUBNET_PE \
    --private-connection-resource-id $SQL_SERVER_ID \
    --group-id sqlServer \
    --connection-name "sqlConnection"
```

**Official Documentation**:
- [az network private-endpoint create](https://learn.microsoft.com/en-us/cli/azure/network/private-endpoint#az-network-private-endpoint-create)
- [Azure Private Link for Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/private-endpoint-overview)

---

#### Task 2B.5: Configure Private DNS Zone

**Objective**: Create a private DNS zone so the VM can resolve the SQL Server's FQDN (`*.database.windows.net`) to its private IP address.

```bash
export DNS_ZONE="privatelink.database.windows.net"

# Create Private DNS Zone
az network private-dns zone create \
    --resource-group $RG_NAME \
    --name $DNS_ZONE

# Link DNS Zone to VNet
az network private-dns link vnet create \
    --resource-group $RG_NAME \
    --zone-name $DNS_ZONE \
    --name "dnslink-text2sql" \
    --virtual-network $VNET_NAME \
    --registration-enabled false

# Create DNS zone group for automatic DNS record registration
az network private-endpoint dns-zone-group create \
    --resource-group $RG_NAME \
    --endpoint-name $PE_NAME \
    --name "sqlDnsZoneGroup" \
    --private-dns-zone $DNS_ZONE \
    --zone-name "sql"
```

**Official Documentation**:
- [Azure Private Endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- [az network private-dns zone create](https://learn.microsoft.com/en-us/cli/azure/network/private-dns/zone#az-network-private-dns-zone-create)

---

#### Task 2B.6: Create VM Inside the VNet (replaces Task 4.1 for Option B)

**Objective**: When using Option B, the VM **must** be deployed into the same VNet to reach the Private Endpoint. Use this task **instead of** Task 4.1.

```bash
export VM_NAME="vm-text2sql-frontend"
export VM_IMAGE="Canonical:0001-com-ubuntu-minimal-jammy:minimal-22_04-lts-gen2:latest"
export VM_SIZE="Standard_B2s"
export VM_ADMIN="azureuser"

az vm create \
    --resource-group $RG_NAME \
    --name $VM_NAME \
    --location $LOCATION_VM \
    --image $VM_IMAGE \
    --size $VM_SIZE \
    --admin-username $VM_ADMIN \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --vnet-name $VNET_NAME \
    --subnet $SUBNET_VM \
    --tags project=text2sql-workshop role=frontend
```

> **Important**: The `--vnet-name` and `--subnet` flags place the VM inside the same VNet as the Private Endpoint. This is the critical difference from Task 4.1 (Option A).

Then continue with **Task 4.2** (open port 8501) onward as normal.

---

#### Task 2B.7: Verify Private Connectivity

**Objective**: Confirm the SQL Server resolves to a private IP (10.0.2.x) from within the VM.

```bash
# SSH into the VM first, then run:
nslookup sql-text2sql-workshop.database.windows.net

# Expected output should show:
#   Address: 10.0.2.4  (or similar private IP from subnet-privateendpoint)
# NOT a public IP address
```

---

#### Task 2B.8: Populate Database with Dummy Data

**Objective**: Identical to Task 2.4. Execute from the VM (since public access is disabled, `sqlcmd` must run from within the VNet).

```bash
# On the VM — install sqlcmd
curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list
sudo apt update
sudo ACCEPT_EULA=Y apt install -y mssql-tools18 unixodbc-dev
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
source ~/.bashrc

# Connect and execute SQL (use the same SQL script from Task 2.4)
sqlcmd -S sql-text2sql-workshop.database.windows.net \
       -U sqladmin \
       -P '<STRONG_PASSWORD_HERE>' \
       -d SalesDB \
       -i seed_data.sql
```

> **Tip**: Save the SQL from Task 2.4 into a file `seed_data.sql` on the VM, then execute with `sqlcmd -i`.

---

#### Option B: Comparison Summary

| Aspect | Option A (Firewall) | Option B (Private Endpoint) |
|---|---|---|
| **Public network access** | Enabled (filtered by IP rules) | Disabled |
| **Firewall rules required** | Yes — Azure services + your IP | No |
| **Network isolation** | Partial (public IP still exposed) | Full (private IP only) |
| **DNS resolution** | Public DNS → public IP | Private DNS → private IP (10.x.x.x) |
| **VM placement** | Any (standalone) | Must be in same VNet |
| **Complexity** | Lower | Moderate (VNet, PE, DNS zone) |
| **Security posture** | Acceptable for dev/workshop | Recommended for production |
| **Additional cost** | None | ~$7.30/month (Private Endpoint) |
| **Data seeding** | From anywhere (with firewall rule) | From within VNet only |

**Official Documentation**:
- [Azure Private Link for Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/private-endpoint-overview)
- [Azure SQL connectivity architecture](https://learn.microsoft.com/en-us/azure/azure-sql/database/connectivity-architecture)
- [Private Endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- [Disable public network access to Azure SQL](https://learn.microsoft.com/en-us/azure/azure-sql/database/connectivity-settings-how-to#deny-public-network-access)

---

### Phase 2C — Azure SQL Database (Option C: Fully Public — Simplest Setup) ★ RECOMMENDED FOR WORKSHOP

> **Selection Guidance**: Choose **Option C** if you want the fastest, simplest deployment with zero networking complexity. SQL Database is fully public (open to all IPs), no firewall configuration needed, and you can query directly from Azure Portal's Query Editor. No VNet, no Private Endpoint, no hub-spoke — just resources in a single resource group. **Ideal for workshops, demos, and quick prototyping.**

> ⚠️ **Security Warning**: This configuration exposes the SQL Server to the public internet. Use strong passwords and **delete all resources immediately after the workshop**. Do **not** use this configuration for production workloads.

#### Task 2C.1: Create Azure SQL Logical Server (Public, Open to All)

**Objective**: Deploy an Azure SQL logical server with public access and a blanket allow-all rule so you can query from Azure Portal, local machine, or the VM without any firewall friction.

```bash
export SQL_SERVER_NAME="sql-text2sql-workshop"
export SQL_ADMIN_USER="sqladmin"
export SQL_ADMIN_PASSWORD="<STRONG_PASSWORD_HERE>"   # Min 8 chars, complex

# Create SQL Server (public access enabled by default)
az sql server create \
    --name $SQL_SERVER_NAME \
    --resource-group $RG_NAME \
    --location $LOCATION_VM \
    --admin-user $SQL_ADMIN_USER \
    --admin-password $SQL_ADMIN_PASSWORD

# Allow ALL IP addresses (0.0.0.0 → 255.255.255.255)
az sql server firewall-rule create \
    --resource-group $RG_NAME \
    --server $SQL_SERVER_NAME \
    --name AllowAll \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 255.255.255.255
```

> **What this does**: A single firewall rule `0.0.0.0 – 255.255.255.255` permits connections from any IP address. This means you can:
> - Query from **Azure Portal → SQL Database → Query Editor** instantly
> - Connect from your **local machine** (SSMS, Azure Data Studio, DBeaver)
> - Connect from the **VM** without any VNet/PE setup
> - No additional firewall rules needed at any point

**Official Documentation**:
- [az sql server create](https://learn.microsoft.com/en-us/cli/azure/sql/server#az-sql-server-create)
- [az sql server firewall-rule create](https://learn.microsoft.com/en-us/cli/azure/sql/server/firewall-rule#az-sql-server-firewall-rule-create)

---

#### Task 2C.2: Create Azure SQL Database

**Objective**: Create the application database. Using `Basic` edition to minimise cost for workshop.

```bash
export SQL_DB_NAME="SalesDB"

az sql db create \
    --resource-group $RG_NAME \
    --server $SQL_SERVER_NAME \
    --name $SQL_DB_NAME \
    --edition Basic \
    --capacity 5 \
    --max-size 2GB
```

> **Cost Note**: `Basic` edition with 5 DTUs costs ~$5/month — significantly cheaper than GeneralPurpose for a workshop.

**Official Documentation**:
- [az sql db create](https://learn.microsoft.com/en-us/cli/azure/sql/db#az-sql-db-create)
- [Azure SQL Database DTU-based pricing](https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tiers-dtu)

---

#### Task 2C.3: Verify Access via Azure Portal Query Editor

**Objective**: Confirm you can query the database directly from the Azure Portal — no tools required.

1. Go to **Azure Portal** → **SQL Databases** → **SalesDB**
2. Click **Query editor (preview)** in the left menu
3. Log in with `sqladmin` / `<your-password>`
4. Run: `SELECT 1 AS test` — should return `1`

> This confirms the fully public setup works. You can use this same Query Editor to run the seed data SQL in the next step.

**Official Documentation**:
- [Azure Portal Query Editor for SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/query-editor)

---

#### Task 2C.4: Populate Database with Dummy Data

**Objective**: Populate the sample data. Use **any** of these methods (all work because the server is fully public):

**Method 1 — Azure Portal Query Editor** (easiest, zero install):
1. Open **Query editor** in Azure Portal (same as Task 2C.3)
2. Copy-paste the full SQL script from Task 2.4 into the editor
3. Click **Run**

**Method 2 — Azure Data Studio / SSMS** (from your local machine):
- Server: `sql-text2sql-workshop.database.windows.net`
- Authentication: SQL Login
- User: `sqladmin` / Password: `<your-password>`
- Database: `SalesDB`

**Method 3 — sqlcmd from anywhere** (CLI):
```bash
sqlcmd -S sql-text2sql-workshop.database.windows.net \
       -U sqladmin \
       -P '<STRONG_PASSWORD_HERE>' \
       -d SalesDB \
       -i seed_data.sql
```

---

#### Task 2C.5: Create VM (Standalone — No VNet Required)

**Objective**: Deploy the VM as a simple standalone instance. Since SQL is fully public, the VM does not need to be in any specific VNet.

```bash
export VM_NAME="vm-text2sql-frontend"
export VM_IMAGE="Canonical:0001-com-ubuntu-minimal-jammy:minimal-22_04-lts-gen2:latest"
export VM_SIZE="Standard_B2s"
export VM_ADMIN="azureuser"

az vm create \
    --resource-group $RG_NAME \
    --name $VM_NAME \
    --location $LOCATION_VM \
    --image $VM_IMAGE \
    --size $VM_SIZE \
    --admin-username $VM_ADMIN \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --tags project=text2sql-workshop role=frontend
```

> **Note**: This is identical to Task 4.1 (Option A). No VNet flags needed. Continue with **Task 4.2** (open port 8501) and onward.

---

#### Option C: Comparison Summary (All Three Options)

| Aspect | Option A (Firewall) | Option B (Private Endpoint) | **Option C (Fully Public)** |
|---|---|---|---|
| **Public network access** | Enabled (filtered by IP) | Disabled | **Enabled (open to all)** |
| **Firewall rules** | Azure services + specific IPs | None (Private Endpoint) | **Single allow-all rule** |
| **Azure Portal Query Editor** | Needs your IP added | Not available (no public access) | **Works immediately** |
| **Network isolation** | Partial | Full | **None** |
| **VM placement** | Any | Must be in VNet | **Any** |
| **VNet / Subnet required** | No | Yes (2 subnets) | **No** |
| **Complexity** | Low | Moderate | **Lowest** |
| **Security posture** | Dev/workshop OK | Production-grade | **Workshop/demo only** |
| **SQL DB edition** | GeneralPurpose (2 vCores) | GeneralPurpose (2 vCores) | **Basic (5 DTU)** |
| **Additional cost** | None | ~$7.30/month (PE) | **None** |
| **Monthly SQL cost** | ~$150 | ~$150 | **~$5** |
| **Data seeding** | From allowed IPs | From within VNet only | **From anywhere** |
| **Total setup steps** | 4 tasks | 8 tasks | **5 tasks** |

---

### Phase 3 — Microsoft Foundry (AI Foundry) Setup

#### Task 3.1: Create AI Foundry Resource and Project

**Objective**: Provision the Microsoft Foundry account and project that will host the AI Agent.

**Via Azure Portal** (recommended for initial setup):
1. Navigate to https://ai.azure.com
2. Click **"Create an agent"** or **"New project"**
3. Select region: `East US` (or any region with GPT-4o support)
4. Note the **Project endpoint** in the format:
   ```
   https://<resource-name>.services.ai.azure.com/api/projects/<project-name>
   ```

**Via Azure CLI** (resource creation):
```bash
# Create the Azure AI Services account (Foundry resource)
az cognitiveservices account create \
    --name "ai-text2sql-workshop" \
    --resource-group $RG_AI_NAME \
    --location $LOCATION_AI \
    --kind AIServices \
    --sku S0 \
    --custom-domain "ai-text2sql-workshop"
```

**Official Documentation**:
- [What is Microsoft Foundry?](https://learn.microsoft.com/en-us/azure/ai-foundry/what-is-foundry)
- [Quickstart: Create a new agent](https://learn.microsoft.com/en-us/azure/ai-services/agents/quickstart)
- [Microsoft Foundry SDKs and Endpoints](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/sdk-overview)
- [Environment setup for Foundry Agent Service](https://learn.microsoft.com/en-us/azure/ai-foundry/agents/environment-setup)

---

#### Task 3.2: Deploy GPT-4o Model

**Objective**: Deploy the GPT-4o model within the Foundry project for Text-to-SQL generation and response synthesis.

**Via Azure Portal**:
1. In https://ai.azure.com → select your project
2. Navigate to **Models + endpoints** → **Deploy model**
3. Select `gpt-4o` → deploy with desired throughput

**Via Azure CLI**:
```bash
az cognitiveservices account deployment create \
    --name "ai-text2sql-workshop" \
    --resource-group $RG_AI_NAME \
    --deployment-name "gpt-4o" \
    --model-name "gpt-4o" \
    --model-version "2024-08-06" \
    --model-format OpenAI \
    --sku-capacity 10 \
    --sku-name "Standard"
```

**Official Documentation**:
- [Deploy models in Microsoft Foundry](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/deploy-models-openai)
- [Azure OpenAI model deployment](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/create-resource)

---

#### Task 3.3: Retrieve API Keys and Endpoint

**Objective**: Obtain the credentials required for programmatic access.

```bash
# Get endpoint
az cognitiveservices account show \
    --name "ai-text2sql-workshop" \
    --resource-group $RG_AI_NAME \
    --query "properties.endpoint" -o tsv

# Get API key
az cognitiveservices account keys list \
    --name "ai-text2sql-workshop" \
    --resource-group $RG_AI_NAME \
    --query "key1" -o tsv
```

Store these securely — they will be used in the application configuration.

**Official Documentation**:
- [az cognitiveservices account keys list](https://learn.microsoft.com/en-us/cli/azure/cognitiveservices/account/keys#az-cognitiveservices-account-keys-list)

---

### Phase 4 — Azure VM Deployment (Frontend Host)

#### Task 4.1: Create Linux Virtual Machine

**Objective**: Deploy an Ubuntu VM in Indonesia Central to serve as the Streamlit frontend host.

```bash
export VM_NAME="vm-text2sql-frontend"
export VM_IMAGE="Canonical:0001-com-ubuntu-minimal-jammy:minimal-22_04-lts-gen2:latest"
export VM_SIZE="Standard_B2s"
export VM_ADMIN="azureuser"

az vm create \
    --resource-group $RG_NAME \
    --name $VM_NAME \
    --location $LOCATION_VM \
    --image $VM_IMAGE \
    --size $VM_SIZE \
    --admin-username $VM_ADMIN \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --tags project=text2sql-workshop role=frontend
```

**Official Documentation**:
- [Quickstart: Create a Linux VM with Azure CLI](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-cli)
- [az vm create](https://learn.microsoft.com/en-us/cli/azure/vm#az-vm-create)

---

#### Task 4.2: Open Port 8501 for Streamlit

**Objective**: Configure the network security group to allow inbound traffic on port 8501 (Streamlit default).

```bash
az vm open-port \
    --resource-group $RG_NAME \
    --name $VM_NAME \
    --port 8501 \
    --priority 1010
```

**Official Documentation**:
- [az vm open-port](https://learn.microsoft.com/en-us/cli/azure/vm#az-vm-open-port)

---

#### Task 4.3: Retrieve VM Public IP Address

**Objective**: Obtain the public IP for SSH access and browser access.

```bash
export VM_IP=$(az vm show \
    --resource-group $RG_NAME \
    --name $VM_NAME \
    --show-details \
    --query publicIps -o tsv)

echo "VM Public IP: $VM_IP"
echo "Streamlit URL: http://$VM_IP:8501"
```

---

#### Task 4.4: SSH into VM and Install Dependencies

**Objective**: Prepare the VM runtime environment.

```bash
ssh $VM_ADMIN@$VM_IP
```

Once connected, execute on the VM:

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install Python 3.11 and pip
sudo apt install -y python3.11 python3.11-venv python3-pip

# Create project directory
mkdir -p ~/text2sql-app && cd ~/text2sql-app

# Create virtual environment
python3.11 -m venv .venv
source .venv/bin/activate

# Install Python dependencies
pip install --upgrade pip
pip install \
    streamlit \
    azure-ai-projects==1.0.0 \
    azure-identity \
    openai \
    pyodbc \
    python-dotenv
```

**Official Documentation**:
- [Install Azure AI Projects SDK](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/sdk-overview)

---

#### Task 4.5: Install ODBC Driver on VM

**Objective**: Install Microsoft ODBC Driver 18 for SQL Server (required by `pyodbc`).

```bash
# On the VM
curl https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list
sudo apt update
sudo ACCEPT_EULA=Y apt install -y msodbcsql18 unixodbc-dev
```

**Official Documentation**:
- [Install the Microsoft ODBC driver for SQL Server (Linux)](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server)

---

### Phase 5 — Application Development

#### Task 5.1: Create Environment Configuration File

**Objective**: Store sensitive configuration in `.env` on the VM.

Create `~/text2sql-app/.env`:

```env
# Microsoft Foundry / AI Foundry
AZURE_AI_PROJECT_ENDPOINT=https://<resource-name>.services.ai.azure.com/api/projects/<project-name>
AZURE_OPENAI_API_KEY=<your-api-key>
AZURE_OPENAI_DEPLOYMENT=gpt-4o

# Azure SQL Database
SQL_SERVER=sql-text2sql-workshop.database.windows.net
SQL_DATABASE=SalesDB
SQL_USERNAME=sqladmin
SQL_PASSWORD=<your-sql-password>
SQL_DRIVER={ODBC Driver 18 for SQL Server}
```

---

#### Task 5.2: Develop the Agentic AI Text-to-SQL Backend

**Objective**: Implement the AI Agent logic that converts natural language to SQL, executes the query, and synthesizes a response.

Create `~/text2sql-app/agent.py`:

```python
"""
Agentic AI Text-to-SQL Backend
Utilises Microsoft Foundry (AI Foundry) to convert natural language
queries into SQL, execute them against Azure SQL Database, and
generate human-readable responses.
"""

import os
import json
import pyodbc
from openai import AzureOpenAI
from dotenv import load_dotenv

load_dotenv()

# --- Database Schema Context ---
DB_SCHEMA = """
Database: SalesDB

Tables:
1. Customers (CustomerID INT PK, FirstName NVARCHAR, LastName NVARCHAR,
   Email NVARCHAR, City NVARCHAR, Country NVARCHAR, CreatedDate DATE)
2. Products (ProductID INT PK, ProductName NVARCHAR, Category NVARCHAR,
   Price DECIMAL, StockQuantity INT)
3. Orders (OrderID INT PK, CustomerID INT FK->Customers, OrderDate DATE,
   TotalAmount DECIMAL, Status NVARCHAR)
4. OrderItems (OrderItemID INT PK, OrderID INT FK->Orders,
   ProductID INT FK->Products, Quantity INT, UnitPrice DECIMAL)

Relationships:
- Orders.CustomerID -> Customers.CustomerID
- OrderItems.OrderID -> Orders.OrderID
- OrderItems.ProductID -> Products.ProductID
"""

SYSTEM_PROMPT = f"""You are an expert SQL analyst agent. Your task is to:
1. Understand the user's natural language question about the database.
2. Generate a valid T-SQL query for Azure SQL Database.
3. Return ONLY the SQL query, no explanations.

{DB_SCHEMA}

Rules:
- Generate only SELECT queries (read-only).
- Use proper JOINs when multiple tables are involved.
- Use aliases for readability.
- Do not use DELETE, UPDATE, INSERT, DROP, or ALTER.
- If the question cannot be answered with the given schema, say "UNSUPPORTED".
"""

SYNTHESIS_PROMPT = """You are a helpful data analyst. Given the user's original
question and the SQL query results, provide a clear, concise, and friendly
natural language answer. Format numbers nicely. If the results are tabular,
present them in a readable format."""


def get_db_connection():
    """Establish connection to Azure SQL Database."""
    conn_str = (
        f"DRIVER={os.getenv('SQL_DRIVER')};"
        f"SERVER={os.getenv('SQL_SERVER')};"
        f"DATABASE={os.getenv('SQL_DATABASE')};"
        f"UID={os.getenv('SQL_USERNAME')};"
        f"PWD={os.getenv('SQL_PASSWORD')};"
        f"Encrypt=yes;TrustServerCertificate=no;"
    )
    return pyodbc.connect(conn_str)


def get_openai_client():
    """Create Azure OpenAI client."""
    return AzureOpenAI(
        api_key=os.getenv("AZURE_OPENAI_API_KEY"),
        api_version="2024-10-21",
        azure_endpoint=os.getenv("AZURE_AI_PROJECT_ENDPOINT").split("/api/")[0],
    )


def generate_sql(client: AzureOpenAI, user_question: str) -> str:
    """Use the AI Agent to convert natural language to SQL."""
    response = client.chat.completions.create(
        model=os.getenv("AZURE_OPENAI_DEPLOYMENT"),
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_question},
        ],
        temperature=0.0,
        max_tokens=500,
    )
    sql_query = response.choices[0].message.content.strip()
    # Clean markdown code blocks if present
    if sql_query.startswith("```"):
        sql_query = sql_query.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    return sql_query


def execute_sql(sql_query: str) -> tuple:
    """Execute SQL query and return results with column names."""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute(sql_query)
    columns = [desc[0] for desc in cursor.description]
    rows = cursor.fetchall()
    conn.close()
    results = [dict(zip(columns, row)) for row in rows]
    return columns, results


def synthesize_response(
    client: AzureOpenAI, user_question: str, sql_query: str, results: list
) -> str:
    """Generate a natural language answer from query results."""
    results_text = json.dumps(results, indent=2, default=str)
    response = client.chat.completions.create(
        model=os.getenv("AZURE_OPENAI_DEPLOYMENT"),
        messages=[
            {"role": "system", "content": SYNTHESIS_PROMPT},
            {
                "role": "user",
                "content": (
                    f"Original question: {user_question}\n\n"
                    f"SQL Query executed:\n{sql_query}\n\n"
                    f"Query Results:\n{results_text}"
                ),
            },
        ],
        temperature=0.3,
        max_tokens=1000,
    )
    return response.choices[0].message.content.strip()


def process_question(user_question: str) -> dict:
    """
    End-to-end pipeline:
    User question -> SQL generation -> Execution -> Synthesis -> Answer
    """
    client = get_openai_client()

    # Step 1: Generate SQL
    sql_query = generate_sql(client, user_question)

    if sql_query == "UNSUPPORTED":
        return {
            "question": user_question,
            "sql_query": None,
            "results": None,
            "answer": "Sorry, I cannot answer that question with the available data.",
            "error": None,
        }

    # Step 2: Execute SQL
    try:
        columns, results = execute_sql(sql_query)
    except Exception as e:
        return {
            "question": user_question,
            "sql_query": sql_query,
            "results": None,
            "answer": None,
            "error": f"SQL execution error: {str(e)}",
        }

    # Step 3: Synthesize Response
    answer = synthesize_response(client, user_question, sql_query, results)

    return {
        "question": user_question,
        "sql_query": sql_query,
        "results": results,
        "answer": answer,
        "error": None,
    }
```

---

#### Task 5.3: Develop the Streamlit Frontend

**Objective**: Create the Streamlit web application that provides the user interface.

Create `~/text2sql-app/app.py`:

```python
"""
Streamlit Frontend — Agentic AI Text-to-SQL
"""

import streamlit as st
from agent import process_question
import json

# --- Page Configuration ---
st.set_page_config(
    page_title="Text-to-SQL Agent",
    page_icon="🤖",
    layout="wide",
)

# --- Header ---
st.title("🤖 Agentic AI — Text to SQL")
st.markdown(
    """
    Ask questions about the **Sales database** in natural language.
    The AI agent will translate your question to SQL, query the database,
    and provide a human-readable answer.
    """
)
st.divider()

# --- Chat History ---
if "messages" not in st.session_state:
    st.session_state.messages = []

for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])
        if "sql_query" in message and message["sql_query"]:
            with st.expander("🔍 View SQL Query"):
                st.code(message["sql_query"], language="sql")
        if "results" in message and message["results"]:
            with st.expander("📊 View Raw Results"):
                st.json(message["results"])

# --- User Input ---
if prompt := st.chat_input("Ask a question about the sales data..."):
    # Display user message
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    # Process with AI Agent
    with st.chat_message("assistant"):
        with st.spinner("🔄 Thinking... Generating SQL and querying database..."):
            result = process_question(prompt)

        if result["error"]:
            st.error(f"Error: {result['error']}")
            if result["sql_query"]:
                st.code(result["sql_query"], language="sql")
            response_content = f"⚠️ {result['error']}"
        else:
            st.markdown(result["answer"])
            if result["sql_query"]:
                with st.expander("🔍 View SQL Query"):
                    st.code(result["sql_query"], language="sql")
            if result["results"]:
                with st.expander("📊 View Raw Results"):
                    st.json(result["results"])
            response_content = result["answer"]

        st.session_state.messages.append(
            {
                "role": "assistant",
                "content": response_content,
                "sql_query": result.get("sql_query"),
                "results": result.get("results"),
            }
        )

# --- Sidebar ---
with st.sidebar:
    st.header("ℹ️ About")
    st.markdown(
        """
        **Architecture:**
        1. User enters natural language question
        2. AI Agent (Microsoft Foundry) generates SQL
        3. SQL executed against Azure SQL Database
        4. Results synthesized into natural language answer

        **Sample Questions:**
        - What are the top 5 customers by total spending?
        - How many orders were placed in December 2025?
        - Which product category has the highest revenue?
        - List all pending orders with customer names.
        - What is the average order value per country?
        """
    )
    st.divider()
    st.markdown("**Workshop:** Agentic AI Text-to-SQL")
    st.markdown("**Region:** Indonesia Central (VM)")
```

---

#### Task 5.4: Deploy Application Files to VM

**Objective**: Transfer application code to the VM.

From your local machine:

```bash
# Copy files to VM
scp agent.py app.py .env $VM_ADMIN@$VM_IP:~/text2sql-app/
```

Or alternatively, clone from a Git repository if one is set up.

---

### Phase 6 — Integration Testing & Validation

#### Task 6.1: Test Database Connectivity from VM

**Objective**: Verify that the VM can connect to Azure SQL Database.

```bash
# On the VM
cd ~/text2sql-app && source .venv/bin/activate
python3 -c "
from agent import get_db_connection
conn = get_db_connection()
cursor = conn.cursor()
cursor.execute('SELECT COUNT(*) FROM Customers')
print(f'Customers count: {cursor.fetchone()[0]}')
conn.close()
print('Database connection successful!')
"
```

---

#### Task 6.2: Test AI Foundry API Connectivity

**Objective**: Verify that the Foundry endpoint and model deployment are accessible.

```bash
# On the VM
python3 -c "
from agent import get_openai_client
client = get_openai_client()
import os
resp = client.chat.completions.create(
    model=os.getenv('AZURE_OPENAI_DEPLOYMENT', 'gpt-4o'),
    messages=[{'role':'user','content':'Say hello'}],
    max_tokens=10,
)
print(resp.choices[0].message.content)
print('AI Foundry connection successful!')
"
```

---

#### Task 6.3: Run End-to-End Agent Test

**Objective**: Test the full pipeline before launching the UI.

```bash
# On the VM
python3 -c "
from agent import process_question
result = process_question('How many customers are from Indonesia?')
print(f'SQL: {result[\"sql_query\"]}')
print(f'Answer: {result[\"answer\"]}')
"
```

---

#### Task 6.4: Launch Streamlit Application

**Objective**: Start the Streamlit application and verify accessibility.

```bash
# On the VM
cd ~/text2sql-app && source .venv/bin/activate
nohup streamlit run app.py \
    --server.port 8501 \
    --server.address 0.0.0.0 \
    --server.headless true \
    > streamlit.log 2>&1 &
```

Access from browser: `http://<VM_PUBLIC_IP>:8501`

---

#### Task 6.5: Validate with Sample Queries

**Objective**: Confirm correct functionality with the following test queries.

| # | Test Query | Expected Behaviour |
|---|---|---|
| 1 | "How many customers are there?" | Returns count = 10 |
| 2 | "What are the top 3 most expensive products?" | Returns Laptop Pro 15, Monitor 27 inch, Noise Cancelling Headphones |
| 3 | "Show total revenue per product category" | Aggregation across OrderItems joined with Products |
| 4 | "Which customers from Indonesia have pending orders?" | JOIN Customers + Orders with filters |
| 5 | "What is the average order value?" | AVG(TotalAmount) from Orders |

---

### Phase 7 — Production Hardening (Optional)

#### Task 7.1: Enable HTTPS with Reverse Proxy

**Objective**: Secure the Streamlit application with TLS.

```bash
# On the VM
sudo apt install -y nginx certbot python3-certbot-nginx

# Configure nginx as reverse proxy for Streamlit
# Then obtain Let's Encrypt certificate
```

**Official Documentation**:
- [Nginx reverse proxy for Streamlit](https://docs.streamlit.io/knowledge-base/deploy/deploy-behind-reverse-proxy)

---

#### Task 7.2: Configure VM Auto-Start for Streamlit

**Objective**: Ensure the Streamlit process starts automatically on VM reboot.

```bash
# Create systemd service
sudo tee /etc/systemd/system/streamlit.service > /dev/null <<EOF
[Unit]
Description=Streamlit Text-to-SQL App
After=network.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/home/azureuser/text2sql-app
ExecStart=/home/azureuser/text2sql-app/.venv/bin/streamlit run app.py \
    --server.port 8501 --server.address 0.0.0.0 --server.headless true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable streamlit
sudo systemctl start streamlit
```

---

#### Task 7.3: Restrict NSG Rules

**Objective**: Limit access to known IP ranges rather than open to all.

```bash
# Remove broad rule and add specific IP range
az network nsg rule update \
    --resource-group $RG_NAME \
    --nsg-name "${VM_NAME}NSG" \
    --name open-port-8501 \
    --source-address-prefixes "<YOUR_CORPORATE_IP_RANGE>"
```

---

## 4. Reference Documentation Index

| # | Topic | Official Documentation URL |
|---|---|---|
| 1 | Azure CLI Installation | https://learn.microsoft.com/en-us/cli/azure/install-azure-cli |
| 2 | Azure CLI Authentication | https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli |
| 3 | Azure Resource Groups | https://learn.microsoft.com/en-us/cli/azure/group |
| 4 | Azure VM Quick Start (Linux CLI) | https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-cli |
| 5 | Azure SQL Database — Create via CLI | https://learn.microsoft.com/en-us/azure/azure-sql/database/scripts/create-and-configure-database-cli |
| 6 | Azure SQL Firewall Rules | https://learn.microsoft.com/en-us/cli/azure/sql/server/firewall-rule |
| 6b | Azure Private Link for Azure SQL | https://learn.microsoft.com/en-us/azure/azure-sql/database/private-endpoint-overview |
| 6c | Private Endpoint DNS Configuration | https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns |
| 6d | Azure SQL Connectivity Architecture | https://learn.microsoft.com/en-us/azure/azure-sql/database/connectivity-architecture |
| 6e | Disable Public Network Access (SQL) | https://learn.microsoft.com/en-us/azure/azure-sql/database/connectivity-settings-how-to |
| 6f | Azure Portal Query Editor (SQL) | https://learn.microsoft.com/en-us/azure/azure-sql/database/query-editor |
| 6g | Azure SQL DTU-based Pricing | https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tiers-dtu |
| 7 | Microsoft Foundry Overview | https://learn.microsoft.com/en-us/azure/ai-foundry/what-is-foundry |
| 8 | Foundry Agent Service Quick Start | https://learn.microsoft.com/en-us/azure/ai-services/agents/quickstart |
| 9 | Foundry SDKs and Endpoints | https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/develop/sdk-overview |
| 10 | Foundry Agent Environment Setup | https://learn.microsoft.com/en-us/azure/ai-foundry/agents/environment-setup |
| 11 | Azure OpenAI Model Deployment | https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/create-resource |
| 12 | ODBC Driver for SQL Server (Linux) | https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server |
| 13 | Azure Regions — Indonesia Central | https://azure.microsoft.com/en-us/explore/global-infrastructure/geographies/ |
| 14 | Streamlit Deployment Guide | https://docs.streamlit.io/deploy |
| 15 | Azure AI Projects Python SDK | https://learn.microsoft.com/en-us/python/api/overview/azure/ai-projects-readme |

---

## 5. Estimated Timeline

| Phase | Description | Estimated Duration |
|---|---|---|
| Phase 1 | Azure Environment Setup | 15 minutes |
| Phase 2 | SQL Database & Dummy Data | 20 minutes |
| Phase 3 | AI Foundry Setup | 20 minutes |
| Phase 4 | VM Deployment & Configuration | 25 minutes |
| Phase 5 | Application Development | 30 minutes |
| Phase 6 | Integration Testing | 15 minutes |
| Phase 7 | Production Hardening (optional) | 30 minutes |
| **Total** | **Core (Phases 1–6)** | **~2 hours** |

---

## 6. Cost Considerations

| Resource | SKU | Estimated Monthly Cost (USD) |
|---|---|---|
| Azure VM (Standard_B2s) | 2 vCPU, 4 GB RAM | ~$38 |
| Azure SQL Database (GP Gen5) | 2 vCores (Option A/B) | ~$150 |
| Azure SQL Database (Basic DTU) | 5 DTU (Option C) | ~$5 |
| Azure OpenAI (GPT-4o) | Pay-per-token | Variable (~$5–50 based on usage) |
| AI Foundry Project | Included with AI Services | $0 (platform fee) |
| Public IP Address | Standard SKU | ~$4 |

> **Tip**: To minimise costs during workshop, deallocate the VM (`az vm deallocate`) and pause/scale-down SQL when not in use.

---

## 7. Clean-Up Commands

```bash
# Delete all resources when workshop is complete
az group delete --name $RG_NAME --yes --no-wait
az group delete --name $RG_AI_NAME --yes --no-wait
```

---

*End of Document*
