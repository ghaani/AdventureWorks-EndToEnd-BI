/* =====================================================================
   Project   : AdventureWorks End-to-End SSIS / SSAS / Power BI
   Phase     : 1 - Data Warehouse Schema (Star Schema DDL)
   Target DB : AdventureWorksDW_Custom
   Source DB : AdventureWorks2025 (OLTP)
   Author    : <your name>
   Notes     : Two fact tables (Internet Sales, Reseller Sales) sharing
               four conformed dimensions (Date, Product, Territory,
               Promotion). DimProduct and DimCustomer implement SCD
               Type 2. See /docs/Phase0_Source_System_Analysis.pdf
               for the full design rationale.
   ===================================================================== */

IF DB_ID('AdventureWorksDW_Custom') IS NULL
BEGIN
    CREATE DATABASE AdventureWorksDW_Custom;
END
GO

USE AdventureWorksDW_Custom;
GO

/* =====================================================================
   1. DIMENSION TABLES
   ===================================================================== */

-- ---------------------------------------------------------------------
-- DimDate  (Static — generated once by a date-generator script)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimDate', 'U') IS NOT NULL DROP TABLE dbo.DimDate;
CREATE TABLE dbo.DimDate (
    DateKey         INT          NOT NULL PRIMARY KEY,   -- yyyymmdd, e.g. 20130115
    FullDate        DATE         NOT NULL,
    DayOfWeek       TINYINT      NOT NULL,               -- 1 = Sunday ... 7 = Saturday
    DayName         VARCHAR(10)  NOT NULL,
    DayOfMonth      TINYINT      NOT NULL,
    DayOfYear        SMALLINT     NOT NULL,
    WeekOfYear      TINYINT      NOT NULL,
    MonthNumber     TINYINT      NOT NULL,
    MonthName       VARCHAR(10)  NOT NULL,
    Quarter         TINYINT      NOT NULL,
    QuarterName     VARCHAR(2)   NOT NULL,               -- Q1..Q4
    Year            SMALLINT     NOT NULL,
    IsWeekend       BIT          NOT NULL,
    FiscalYear      SMALLINT     NOT NULL,               -- AdventureWorks fiscal year starts July 1
    FiscalQuarter   TINYINT      NOT NULL
);
GO

-- ---------------------------------------------------------------------
-- DimProduct  (SCD Type 2)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimProduct', 'U') IS NOT NULL DROP TABLE dbo.DimProduct;
CREATE TABLE dbo.DimProduct (
    ProductKey              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,  -- surrogate key
    ProductAlternateKey     INT          NOT NULL,                   -- OLTP Production.Product.ProductID
    ProductName             NVARCHAR(50) NOT NULL,
    ProductNumber           NVARCHAR(25) NOT NULL,
    Color                   NVARCHAR(15) NULL,
    Size                    NVARCHAR(5)  NULL,
    Weight                  DECIMAL(8,2) NULL,
    StandardCost            MONEY        NULL,
    ListPrice               MONEY        NULL,
    ProductSubcategoryName  NVARCHAR(50) NULL,
    ProductCategoryName     NVARCHAR(50) NULL,
    ProductLine             NVARCHAR(2)  NULL,
    Class                   NVARCHAR(2)  NULL,
    Style                   NVARCHAR(2)  NULL,
    -- SCD Type 2 tracking columns
    StartDate               DATETIME     NOT NULL DEFAULT ('1900-01-01'),
    EndDate                 DATETIME     NULL,
    IsCurrent               BIT          NOT NULL DEFAULT (1)
);
CREATE INDEX IX_DimProduct_AlternateKey ON dbo.DimProduct (ProductAlternateKey, IsCurrent);
GO

-- ---------------------------------------------------------------------
-- DimCustomer  (SCD Type 2)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimCustomer', 'U') IS NOT NULL DROP TABLE dbo.DimCustomer;
CREATE TABLE dbo.DimCustomer (
    CustomerKey             INT IDENTITY(1,1) NOT NULL PRIMARY KEY,  -- surrogate key
    CustomerAlternateKey    INT          NOT NULL,                   -- OLTP Sales.Customer.CustomerID
    FirstName               NVARCHAR(50) NULL,
    LastName                NVARCHAR(50) NULL,
    FullName                NVARCHAR(100) NULL,
    EmailAddress            NVARCHAR(50) NULL,
    City                    NVARCHAR(30) NULL,
    StateProvinceName       NVARCHAR(50) NULL,
    CountryRegionName       NVARCHAR(50) NULL,
    PostalCode              NVARCHAR(15) NULL,
    -- SCD Type 2 tracking columns
    StartDate               DATETIME     NOT NULL DEFAULT ('1900-01-01'),
    EndDate                 DATETIME     NULL,
    IsCurrent               BIT          NOT NULL DEFAULT (1)
);
CREATE INDEX IX_DimCustomer_AlternateKey ON dbo.DimCustomer (CustomerAlternateKey, IsCurrent);
GO

-- ---------------------------------------------------------------------
-- DimReseller  (Type 1)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimReseller', 'U') IS NOT NULL DROP TABLE dbo.DimReseller;
CREATE TABLE dbo.DimReseller (
    ResellerKey             INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    ResellerAlternateKey    INT          NOT NULL,                   -- OLTP Sales.Store.BusinessEntityID
    ResellerName            NVARCHAR(50) NOT NULL,
    City                    NVARCHAR(30) NULL,
    StateProvinceName       NVARCHAR(50) NULL,
    CountryRegionName       NVARCHAR(50) NULL
);
CREATE UNIQUE INDEX IX_DimReseller_AlternateKey ON dbo.DimReseller (ResellerAlternateKey);
GO

-- ---------------------------------------------------------------------
-- DimSalesTerritory  (Type 1)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimSalesTerritory', 'U') IS NOT NULL DROP TABLE dbo.DimSalesTerritory;
CREATE TABLE dbo.DimSalesTerritory (
    TerritoryKey                INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    TerritoryAlternateKey       INT          NOT NULL,                -- OLTP Sales.SalesTerritory.TerritoryID
    TerritoryName                NVARCHAR(50) NOT NULL,
    TerritoryCountry             NVARCHAR(50) NULL,
    TerritoryGroup                NVARCHAR(50) NULL
);
CREATE UNIQUE INDEX IX_DimSalesTerritory_AlternateKey ON dbo.DimSalesTerritory (TerritoryAlternateKey);
GO

-- ---------------------------------------------------------------------
-- DimSalesPerson  (Type 1)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimSalesPerson', 'U') IS NOT NULL DROP TABLE dbo.DimSalesPerson;
CREATE TABLE dbo.DimSalesPerson (
    SalesPersonKey           INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SalesPersonAlternateKey  INT          NOT NULL,                   -- OLTP Sales.SalesPerson.BusinessEntityID
    FullName                 NVARCHAR(100) NOT NULL,
    JobTitle                 NVARCHAR(50) NULL,
    SalesQuota               MONEY        NULL
);
CREATE UNIQUE INDEX IX_DimSalesPerson_AlternateKey ON dbo.DimSalesPerson (SalesPersonAlternateKey);
GO

-- ---------------------------------------------------------------------
-- DimPromotion  (Type 1)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimPromotion', 'U') IS NOT NULL DROP TABLE dbo.DimPromotion;
CREATE TABLE dbo.DimPromotion (
    PromotionKey             INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    PromotionAlternateKey    INT          NOT NULL,                   -- OLTP Sales.SpecialOffer.SpecialOfferID
    PromotionName            NVARCHAR(255) NOT NULL,
    DiscountPct              DECIMAL(5,2) NULL,
    PromotionType            NVARCHAR(50) NULL,
    PromotionCategory        NVARCHAR(50) NULL
);
CREATE UNIQUE INDEX IX_DimPromotion_AlternateKey ON dbo.DimPromotion (PromotionAlternateKey);
GO

-- ---------------------------------------------------------------------
-- DimCurrency  (Type 1)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimCurrency', 'U') IS NOT NULL DROP TABLE dbo.DimCurrency;
CREATE TABLE dbo.DimCurrency (
    CurrencyKey              INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CurrencyAlternateKey     NCHAR(3)     NOT NULL,                   -- ISO code, OLTP Sales.Currency.CurrencyCode
    CurrencyName             NVARCHAR(50) NOT NULL
);
CREATE UNIQUE INDEX IX_DimCurrency_AlternateKey ON dbo.DimCurrency (CurrencyAlternateKey);
GO

-- ---------------------------------------------------------------------
-- DimGeography  (Type 1)
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.DimGeography', 'U') IS NOT NULL DROP TABLE dbo.DimGeography;
CREATE TABLE dbo.DimGeography (
    GeographyKey             INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    City                     NVARCHAR(30) NULL,
    StateProvinceName        NVARCHAR(50) NULL,
    CountryRegionName        NVARCHAR(50) NULL,
    PostalCode               NVARCHAR(15) NULL
);
GO

/* =====================================================================
   2. FACT TABLES
   ===================================================================== */

-- ---------------------------------------------------------------------
-- FactInternetSales
-- Grain: one row per line item of an online order placed by an
--        individual customer (Customer.StoreID IS NULL in OLTP).
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.FactInternetSales', 'U') IS NOT NULL DROP TABLE dbo.FactInternetSales;
CREATE TABLE dbo.FactInternetSales (
    -- Degenerate dimension (kept on the fact, not worth its own dim table)
    SalesOrderNumber     NVARCHAR(25) NOT NULL,
    SalesOrderLineNumber TINYINT      NOT NULL,

    -- Foreign keys to conformed + private dimensions
    OrderDateKey         INT NOT NULL REFERENCES dbo.DimDate (DateKey),
    DueDateKey           INT NOT NULL REFERENCES dbo.DimDate (DateKey),
    ShipDateKey          INT NULL     REFERENCES dbo.DimDate (DateKey),
    ProductKey           INT NOT NULL REFERENCES dbo.DimProduct (ProductKey),
    CustomerKey          INT NOT NULL REFERENCES dbo.DimCustomer (CustomerKey),
    TerritoryKey         INT NOT NULL REFERENCES dbo.DimSalesTerritory (TerritoryKey),
    PromotionKey         INT NOT NULL REFERENCES dbo.DimPromotion (PromotionKey),
    CurrencyKey          INT NOT NULL REFERENCES dbo.DimCurrency (CurrencyKey),

    -- Measures
    OrderQty             SMALLINT     NOT NULL,
    UnitPrice            MONEY        NOT NULL,
    UnitPriceDiscount    DECIMAL(5,2) NOT NULL DEFAULT (0),
    ExtendedAmount       MONEY        NOT NULL,   -- OrderQty * UnitPrice
    TaxAmt               MONEY        NOT NULL DEFAULT (0),
    Freight              MONEY        NOT NULL DEFAULT (0),
    LineTotal             MONEY        NOT NULL,   -- ExtendedAmount - Discount

    CONSTRAINT PK_FactInternetSales PRIMARY KEY (SalesOrderNumber, SalesOrderLineNumber)
);
CREATE INDEX IX_FactInternetSales_OrderDateKey ON dbo.FactInternetSales (OrderDateKey);
CREATE INDEX IX_FactInternetSales_ProductKey   ON dbo.FactInternetSales (ProductKey);
CREATE INDEX IX_FactInternetSales_CustomerKey  ON dbo.FactInternetSales (CustomerKey);
GO

-- ---------------------------------------------------------------------
-- FactResellerSales
-- Grain: one row per line item of an order placed by a reseller/store
--        (Customer.StoreID IS NOT NULL in OLTP), attributed to a
--        sales person.
-- ---------------------------------------------------------------------
IF OBJECT_ID('dbo.FactResellerSales', 'U') IS NOT NULL DROP TABLE dbo.FactResellerSales;
CREATE TABLE dbo.FactResellerSales (
    SalesOrderNumber     NVARCHAR(25) NOT NULL,
    SalesOrderLineNumber TINYINT      NOT NULL,

    OrderDateKey         INT NOT NULL REFERENCES dbo.DimDate (DateKey),
    DueDateKey           INT NOT NULL REFERENCES dbo.DimDate (DateKey),
    ShipDateKey          INT NULL     REFERENCES dbo.DimDate (DateKey),
    ProductKey           INT NOT NULL REFERENCES dbo.DimProduct (ProductKey),
    ResellerKey          INT NOT NULL REFERENCES dbo.DimReseller (ResellerKey),
    TerritoryKey         INT NOT NULL REFERENCES dbo.DimSalesTerritory (TerritoryKey),
    SalesPersonKey       INT NOT NULL REFERENCES dbo.DimSalesPerson (SalesPersonKey),
    PromotionKey         INT NOT NULL REFERENCES dbo.DimPromotion (PromotionKey),

    OrderQty             SMALLINT     NOT NULL,
    UnitPrice            MONEY        NOT NULL,
    UnitPriceDiscount    DECIMAL(5,2) NOT NULL DEFAULT (0),
    ExtendedAmount       MONEY        NOT NULL,
    TaxAmt               MONEY        NOT NULL DEFAULT (0),
    Freight              MONEY        NOT NULL DEFAULT (0),
    LineTotal             MONEY        NOT NULL,

    CONSTRAINT PK_FactResellerSales PRIMARY KEY (SalesOrderNumber, SalesOrderLineNumber)
);
CREATE INDEX IX_FactResellerSales_OrderDateKey   ON dbo.FactResellerSales (OrderDateKey);
CREATE INDEX IX_FactResellerSales_ProductKey     ON dbo.FactResellerSales (ProductKey);
CREATE INDEX IX_FactResellerSales_ResellerKey    ON dbo.FactResellerSales (ResellerKey);
CREATE INDEX IX_FactResellerSales_SalesPersonKey ON dbo.FactResellerSales (SalesPersonKey);
GO

/* =====================================================================
   3. "UNKNOWN MEMBER" ROWS
   Every dimension gets a row for surrogate key 0 (or a defined
   alternate key) to catch late-arriving / unmatched fact rows during
   SSIS lookups instead of failing the load.
   ===================================================================== */

SET IDENTITY_INSERT dbo.DimProduct ON;
INSERT INTO dbo.DimProduct (ProductKey, ProductAlternateKey, ProductName, ProductNumber, StartDate, IsCurrent)
VALUES (0, -1, 'Unknown Product', 'N/A', '1900-01-01', 1);
SET IDENTITY_INSERT dbo.DimProduct OFF;

SET IDENTITY_INSERT dbo.DimCustomer ON;
INSERT INTO dbo.DimCustomer (CustomerKey, CustomerAlternateKey, FullName, StartDate, IsCurrent)
VALUES (0, -1, 'Unknown Customer', '1900-01-01', 1);
SET IDENTITY_INSERT dbo.DimCustomer OFF;

SET IDENTITY_INSERT dbo.DimReseller ON;
INSERT INTO dbo.DimReseller (ResellerKey, ResellerAlternateKey, ResellerName)
VALUES (0, -1, 'Unknown Reseller');
SET IDENTITY_INSERT dbo.DimReseller OFF;

SET IDENTITY_INSERT dbo.DimSalesTerritory ON;
INSERT INTO dbo.DimSalesTerritory (TerritoryKey, TerritoryAlternateKey, TerritoryName)
VALUES (0, -1, 'Unknown Territory');
SET IDENTITY_INSERT dbo.DimSalesTerritory OFF;

SET IDENTITY_INSERT dbo.DimSalesPerson ON;
INSERT INTO dbo.DimSalesPerson (SalesPersonKey, SalesPersonAlternateKey, FullName)
VALUES (0, -1, 'Unknown Sales Person');
SET IDENTITY_INSERT dbo.DimSalesPerson OFF;

SET IDENTITY_INSERT dbo.DimPromotion ON;
INSERT INTO dbo.DimPromotion (PromotionKey, PromotionAlternateKey, PromotionName)
VALUES (0, -1, 'No Promotion');
SET IDENTITY_INSERT dbo.DimPromotion OFF;

SET IDENTITY_INSERT dbo.DimCurrency ON;
INSERT INTO dbo.DimCurrency (CurrencyKey, CurrencyAlternateKey, CurrencyName)
VALUES (0, 'N/A', 'Unknown Currency');
SET IDENTITY_INSERT dbo.DimCurrency OFF;
GO
