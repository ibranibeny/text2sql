-- =============================================================================
-- seed_data.sql — Sample Sales Database for Text-to-SQL Workshop
-- =============================================================================
--
-- This script creates and populates the SalesDB schema used by the
-- Agentic AI Text-to-SQL demo. Run against Azure SQL Database.
--
-- Usage (from VM or local machine):
--   sqlcmd -S <server>.database.windows.net -d SalesDB \
--          -U sqladmin -P '<password>' -i seed_data.sql
--
-- =============================================================================

-- -----------------------------------------------------------
-- Table: Customers
-- -----------------------------------------------------------
IF OBJECT_ID('dbo.OrderItems', 'U') IS NOT NULL DROP TABLE dbo.OrderItems;
IF OBJECT_ID('dbo.Orders', 'U') IS NOT NULL DROP TABLE dbo.Orders;
IF OBJECT_ID('dbo.Products', 'U') IS NOT NULL DROP TABLE dbo.Products;
IF OBJECT_ID('dbo.Customers', 'U') IS NOT NULL DROP TABLE dbo.Customers;

CREATE TABLE dbo.Customers (
    CustomerID   INT           PRIMARY KEY,
    FirstName    NVARCHAR(50)  NOT NULL,
    LastName     NVARCHAR(50)  NOT NULL,
    Email        NVARCHAR(100) NOT NULL UNIQUE,
    City         NVARCHAR(50)  NOT NULL,
    Country      NVARCHAR(50)  NOT NULL DEFAULT 'Indonesia',
    JoinDate     DATE          NOT NULL
);

INSERT INTO dbo.Customers (CustomerID, FirstName, LastName, Email, City, Country, JoinDate) VALUES
(1,  'Adi',     'Pratama',   'adi.pratama@mail.com',    'Jakarta',    'Indonesia', '2023-01-15'),
(2,  'Siti',    'Rahayu',    'siti.rahayu@mail.com',    'Surabaya',   'Indonesia', '2023-02-20'),
(3,  'Budi',    'Santoso',   'budi.santoso@mail.com',   'Bandung',    'Indonesia', '2023-03-10'),
(4,  'Dewi',    'Lestari',   'dewi.lestari@mail.com',   'Yogyakarta', 'Indonesia', '2023-04-05'),
(5,  'Rudi',    'Hermawan',  'rudi.hermawan@mail.com',  'Semarang',   'Indonesia', '2023-05-12'),
(6,  'Ayu',     'Wulandari', 'ayu.wulandari@mail.com',  'Medan',      'Indonesia', '2023-06-18'),
(7,  'Agus',    'Suryadi',   'agus.suryadi@mail.com',   'Makassar',   'Indonesia', '2023-07-22'),
(8,  'Rina',    'Fitriani',  'rina.fitriani@mail.com',  'Denpasar',   'Indonesia', '2023-08-30'),
(9,  'Hendra',  'Wijaya',    'hendra.wijaya@mail.com',  'Palembang',  'Indonesia', '2023-09-14'),
(10, 'Maya',    'Kusuma',    'maya.kusuma@mail.com',     'Malang',     'Indonesia', '2023-10-01');

-- -----------------------------------------------------------
-- Table: Products
-- -----------------------------------------------------------
CREATE TABLE dbo.Products (
    ProductID    INT            PRIMARY KEY,
    ProductName  NVARCHAR(100)  NOT NULL,
    Category     NVARCHAR(50)   NOT NULL,
    Price        DECIMAL(10,2)  NOT NULL,
    Stock        INT            NOT NULL DEFAULT 0
);

INSERT INTO dbo.Products (ProductID, ProductName, Category, Price, Stock) VALUES
(1,  'Laptop ProBook 14',    'Electronics', 12500000.00,  50),
(2,  'Wireless Mouse M200',  'Electronics',   250000.00, 200),
(3,  'USB-C Hub 7-in-1',     'Electronics',   450000.00, 150),
(4,  'Mechanical Keyboard',  'Electronics',   850000.00, 100),
(5,  'Monitor 27" 4K',       'Electronics',  5500000.00,  30),
(6,  'Office Chair Ergon',   'Furniture',    3200000.00,  40),
(7,  'Standing Desk 120cm',  'Furniture',    4800000.00,  25),
(8,  'Notebook A5 Pack-5',   'Stationery',    75000.00, 500),
(9,  'Ballpoint Pen Box-12', 'Stationery',    48000.00, 300),
(10, 'Webcam HD 1080p',      'Electronics',   650000.00,  80);

-- -----------------------------------------------------------
-- Table: Orders
-- -----------------------------------------------------------
CREATE TABLE dbo.Orders (
    OrderID      INT            PRIMARY KEY,
    CustomerID   INT            NOT NULL REFERENCES dbo.Customers(CustomerID),
    OrderDate    DATE           NOT NULL,
    TotalAmount  DECIMAL(12,2)  NOT NULL,
    Status       NVARCHAR(20)   NOT NULL DEFAULT 'Completed'
);

INSERT INTO dbo.Orders (OrderID, CustomerID, OrderDate, TotalAmount, Status) VALUES
(1001, 1,  '2024-01-10', 13200000.00, 'Completed'),
(1002, 2,  '2024-01-15',   850000.00, 'Completed'),
(1003, 3,  '2024-02-01',  5750000.00, 'Completed'),
(1004, 1,  '2024-02-14',   700000.00, 'Completed'),
(1005, 4,  '2024-03-05',  8000000.00, 'Completed'),
(1006, 5,  '2024-03-20',   123000.00, 'Completed'),
(1007, 6,  '2024-04-01', 12500000.00, 'Shipped'),
(1008, 7,  '2024-04-15',  3200000.00, 'Shipped'),
(1009, 2,  '2024-05-01',  5500000.00, 'Processing'),
(1010, 8,  '2024-05-10',   525000.00, 'Processing'),
(1011, 9,  '2024-06-01',  4800000.00, 'Completed'),
(1012, 10, '2024-06-15',   650000.00, 'Completed'),
(1013, 3,  '2024-07-01', 16300000.00, 'Completed');

-- -----------------------------------------------------------
-- Table: OrderItems
-- -----------------------------------------------------------
CREATE TABLE dbo.OrderItems (
    OrderItemID  INT            PRIMARY KEY,
    OrderID      INT            NOT NULL REFERENCES dbo.Orders(OrderID),
    ProductID    INT            NOT NULL REFERENCES dbo.Products(ProductID),
    Quantity     INT            NOT NULL,
    UnitPrice    DECIMAL(10,2)  NOT NULL,
    LineTotal    AS (Quantity * UnitPrice) PERSISTED
);

INSERT INTO dbo.OrderItems (OrderItemID, OrderID, ProductID, Quantity, UnitPrice) VALUES
(1,  1001, 1, 1,  12500000.00),
(2,  1001, 3, 1,    450000.00),
(3,  1001, 2, 1,    250000.00),
(4,  1002, 4, 1,    850000.00),
(5,  1003, 5, 1,   5500000.00),
(6,  1003, 2, 1,    250000.00),
(7,  1004, 3, 1,    450000.00),
(8,  1004, 2, 1,    250000.00),
(9,  1005, 7, 1,   4800000.00),
(10, 1005, 6, 1,   3200000.00),
(11, 1006, 8, 1,     75000.00),
(12, 1006, 9, 1,     48000.00),
(13, 1007, 1, 1,  12500000.00),
(14, 1008, 6, 1,   3200000.00),
(15, 1009, 5, 1,   5500000.00),
(16, 1010, 10, 1,   650000.00),
(17, 1011, 7, 1,   4800000.00),
(18, 1012, 10, 1,   650000.00),
(19, 1013, 1, 1,  12500000.00),
(20, 1013, 4, 1,    850000.00),
(21, 1013, 5, 1,   5500000.00),
(22, 1013, 3, 2,    450000.00);

-- -----------------------------------------------------------
-- Verification
-- -----------------------------------------------------------
SELECT 'Customers' AS TableName, COUNT(*) AS RowCount FROM dbo.Customers
UNION ALL
SELECT 'Products',  COUNT(*) FROM dbo.Products
UNION ALL
SELECT 'Orders',    COUNT(*) FROM dbo.Orders
UNION ALL
SELECT 'OrderItems', COUNT(*) FROM dbo.OrderItems;

PRINT '✓ SalesDB seed data loaded successfully.';
