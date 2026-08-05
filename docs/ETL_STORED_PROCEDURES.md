# ETL Stored Procedures — Documentation

This file documents the Stored Procedures created to work around a limitation in SSIS's OLE DB Source when it comes to automatic parameter detection.

## Why were these SPs needed?

In SSIS, the OLE DB Source relies on a simple parser to automatically extract parameters (`?`) from SQL text. This parser fails on complex queries — particularly those containing a CTE (`WITH ... AS`), `ROW_NUMBER() OVER`, or nested subqueries — and raises the following error:

```
Parameters cannot be extracted from the SQL command. The provider might not
help to parse parameter information from the command...
Syntax error or access violation (Microsoft OLE DB Provider for SQL Server)
```

The standard solution adopted in this project: move the complex query logic into a **Stored Procedure** under the `ETL` schema, and call it from the OLE DB Source using a simple `EXEC` statement, which the parser can handle without issue.

> **Usage rule:** This pattern is applied only to queries that actually hit the error above — not by default for every dimension/fact table.

## How to use it in OLE DB Source

1. Set `Data access mode` to `SQL Command` (not Variable — the Parameters option is not shown at all in Variable mode).
2. Command text:
   ```sql
   EXEC ETL.usp_GetDim<Name>Incremental @LastWatermark = ?
   ```
3. In the **Parameters** dialog, map the parameter to the package's watermark variable (e.g. `User::LastWatermarkDate`).
4. The explicit form `@LastWatermark = ?` (rather than just `?`) is used because it produced a more reliable parameter mapping with the MSOLEDBSQL driver.

---

## 1. ETL.usp_GetDimCustomerIncremental

**Target table:** DimCustomer
**Parameter:** `@LastWatermark DATETIME`
**Change-detection logic:** checks `ModifiedDate` across four sources: `Sales.Customer`, `Person.Person`, `Person.EmailAddress`, and the address chain (`BusinessEntityAddress` → `Address` → `StateProvince` → `CountryRegion`).

```sql
CREATE PROCEDURE ETL.usp_GetDimCustomerIncremental
    @LastWatermark DATETIME
AS
BEGIN
    SET NOCOUNT ON;

    WITH CustomerAddress AS (
        SELECT
            bea.BusinessEntityID,
            a.City,
            sp.Name AS StateProvinceName,
            cr.Name AS CountryRegionName,
            a.PostalCode,
            (SELECT MAX(v) FROM (VALUES (bea.ModifiedDate),(a.ModifiedDate),(sp.ModifiedDate),(cr.ModifiedDate)) AS x(v)) AS AddressChainModifiedDate,
            ROW_NUMBER() OVER (
                PARTITION BY bea.BusinessEntityID
                ORDER BY CASE WHEN at.Name IN ('Main Office', 'Home') THEN 0 ELSE 1 END
            ) AS rn
        FROM Person.BusinessEntityAddress bea
        INNER JOIN Person.Address a         ON bea.AddressID = a.AddressID
        INNER JOIN Person.StateProvince sp  ON a.StateProvinceID = sp.StateProvinceID
        INNER JOIN Person.CountryRegion cr  ON sp.CountryRegionCode = cr.CountryRegionCode
        INNER JOIN Person.AddressType at    ON bea.AddressTypeID = at.AddressTypeID
    )
    SELECT
        c.CustomerID                          AS CustomerAlternateKey,
        p.FirstName,
        p.LastName,
        p.FirstName + ' ' + p.LastName        AS FullName,
        ea.EmailAddress,
        ca.City,
        ca.StateProvinceName,
        ca.CountryRegionName,
        ca.PostalCode
    FROM Sales.Customer c
    INNER JOIN Person.Person p          ON c.PersonID = p.BusinessEntityID
    LEFT JOIN Person.EmailAddress ea    ON p.BusinessEntityID = ea.BusinessEntityID
    LEFT JOIN CustomerAddress ca        ON p.BusinessEntityID = ca.BusinessEntityID AND ca.rn = 1
    WHERE c.StoreID IS NULL   -- Internet Sales scope, unchanged from the full-load version
      AND (
            c.ModifiedDate > @LastWatermark
         OR p.ModifiedDate > @LastWatermark
         OR ISNULL(ea.ModifiedDate, '1900-01-01') > @LastWatermark
         OR ISNULL(ca.AddressChainModifiedDate, '1900-01-01') > @LastWatermark
      );
END
```

**Call from OLE DB Source:**
```sql
EXEC ETL.usp_GetDimCustomerIncremental @LastWatermark = ?
```

---

## 2. ETL.usp_GetDimResellerIncremental

**Target table:** DimReseller
**Parameter:** `@LastWatermark DATETIME`
**Change-detection logic:** checks `ModifiedDate` on `Sales.Store` and the store's address chain (`BusinessEntityAddress` → `Address` → `StateProvince` → `CountryRegion`).

```sql
CREATE PROCEDURE ETL.usp_GetDimResellerIncremental
    @LastWatermark DATETIME
AS
BEGIN
    SET NOCOUNT ON;

    WITH StoreAddress AS (
        SELECT
            bea.BusinessEntityID,
            a.City,
            sp.Name AS StateProvinceName,
            cr.Name AS CountryRegionName,
            (SELECT MAX(v) FROM (VALUES (bea.ModifiedDate),(a.ModifiedDate),(sp.ModifiedDate),(cr.ModifiedDate)) AS x(v)) AS AddressChainModifiedDate,
            ROW_NUMBER() OVER (
                PARTITION BY bea.BusinessEntityID
                ORDER BY CASE WHEN at.Name = 'Main Office' THEN 0 ELSE 1 END
            ) AS rn
        FROM Person.BusinessEntityAddress bea
        INNER JOIN Person.Address a         ON bea.AddressID = a.AddressID
        INNER JOIN Person.StateProvince sp  ON a.StateProvinceID = sp.StateProvinceID
        INNER JOIN Person.CountryRegion cr  ON sp.CountryRegionCode = cr.CountryRegionCode
        INNER JOIN Person.AddressType at    ON bea.AddressTypeID = at.AddressTypeID
    )
    SELECT
        s.BusinessEntityID   AS ResellerAlternateKey,
        s.Name                AS ResellerName,
        sa.City,
        sa.StateProvinceName,
        sa.CountryRegionName
    FROM Sales.Store s
    LEFT JOIN StoreAddress sa
        ON s.BusinessEntityID = sa.BusinessEntityID AND sa.rn = 1
    WHERE
          s.ModifiedDate > @LastWatermark
       OR ISNULL(sa.AddressChainModifiedDate, '1900-01-01') > @LastWatermark;
END
```

**Call from OLE DB Source:**
```sql
EXEC ETL.usp_GetDimResellerIncremental @LastWatermark = ?
```

---

## Common notes

- Both SPs live in the `ETL` schema (not `dbo`) to keep them separate from core business logic.
- The address-chain pattern (`AddressChainModifiedDate` via `VALUES` + `MAX`) is identical in both SPs and can be reused for similar dimensions in the future.
- If the same error occurs for the Fact tables (FactInternetSales / FactResellerSales), this pattern will be repeated and added to this file.
