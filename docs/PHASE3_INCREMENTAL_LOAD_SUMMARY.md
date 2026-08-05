# Phase 3 — Incremental Load Summary

This document summarizes the implementation of incremental (delta) loading for the AdventureWorks BI project, covering all dimension and fact tables.

## Approach

Each table's SSIS package uses a watermark-based incremental pattern: a stored watermark value (`LastWatermarkDate`, tracked as an SSIS package variable) is compared against `ModifiedDate` columns on the source tables that actually supply the row's output columns. Only rows changed since the last successful load are extracted.

Two implementation patterns were used, depending on query complexity:

1. **Direct parameterized `SQL Command`** — used when the OLE DB Source's automatic parameter parser could handle the query as-is.
2. **Stored Procedure (`EXEC ... @LastWatermark = ?`)** — used only when the query was too complex (typically due to CTEs combined with window functions) for the OLE DB parser to extract parameters from. See `ETL_STORED_PROCEDURES.md` for the two procedures created under this pattern.

## Dimensions

| Dimension | Pattern | Notes |
|---|---|---|
| DimSalesTerritory | Direct SQL Command | Simple query, no CTE |
| DimCurrency | Direct SQL Command | Simple query, no CTE |
| DimPromotion | Direct SQL Command | Simple query, no CTE |
| DimCustomer | Stored Procedure | CTE + window function triggered OLE DB parameter-parsing error; resolved via `ETL.usp_GetDimCustomerIncremental` |
| DimGeography | Direct SQL Command | |
| DimProduct | Direct SQL Command | |
| DimReseller | Stored Procedure | Same CTE/window-function issue as DimCustomer; resolved via `ETL.usp_GetDimResellerIncremental` |
| DimSalesPerson | Direct SQL Command | |
| DimDate | Not applicable | Static/generated calendar dimension — no incremental load required |

## Fact Tables

| Fact Table | Pattern | Change-detection columns |
|---|---|---|
| FactInternetSales | Direct SQL Command | `SalesOrderHeader.ModifiedDate`, `SalesOrderDetail.ModifiedDate` |
| FactResellerSales | Direct SQL Command | `SalesOrderHeader.ModifiedDate`, `SalesOrderDetail.ModifiedDate` |

Both fact tables share the same grain (one row per sales order line) and the same join structure (`SalesOrderDetail` → `SalesOrderHeader` → `Customer`, with `Customer.StoreID` used only to route rows between Internet Sales and Reseller Sales — not as a watermark source, since it contributes no output column).

## Key design rule: which tables belong in the watermark condition

Only tables that directly supply an output column (a business key, attribute, or measure) are checked in the `WHERE` clause. Tables used purely for filtering or as join bridges (e.g. `Customer` in the fact queries, `AddressType` in the dimension queries) are excluded — their `ModifiedDate` has no bearing on whether the output row's content has changed, and including them would trigger unnecessary reprocessing.

## Key design rule: when to convert a query into a Stored Procedure

The Stored-Procedure pattern is applied only reactively — i.e., only for queries that actually fail with the OLE DB parameter-parsing error, not as a default for every dimension/fact. This keeps most of the SSIS packages simpler (plain parameterized `SQL Command`) and reserves the extra layer for the cases that genuinely need it.

## Outcome

All 8 incrementally-loaded dimensions and both fact tables have been implemented and tested successfully. Phase 3 is complete.
