# Phase 4 — SSAS Tabular Model Summary

This document summarizes the implementation of the SSAS Tabular semantic model for the AdventureWorks BI project.

## Project setup

- **Project type:** Analysis Services Tabular Project (Visual Studio / SSDT)
- **Compatibility Level:** 1700
- **Data source:** the custom Data Warehouse (`AdventureWorksDW_Custom`), not the OLTP source
- **Tables imported:** all 8 incrementally-loaded dimensions (DimCustomer, DimProduct, DimSalesTerritory, DimCurrency, DimPromotion, DimReseller, DimSalesPerson) plus the static DimDate, and both fact tables (FactInternetSales, FactResellerSales)

## Model architecture decision

A **single unified Tabular model** was used (rather than two separate models for Internet Sales and Reseller Sales), with **conformed dimensions** shared between both fact tables (DimDate, DimProduct, DimSalesTerritory, DimCurrency, DimPromotion). This directly supports the project's business scenario, which requires analyzing and comparing Internet Sales and Reseller Sales side by side.

## DimGeography — excluded from the model

`DimGeography` was found to be an orphaned table with no relationship to any other table in the model. Root cause: `City`, `StateProvinceName`, and `CountryRegionName` had been denormalized directly into `DimCustomer` and `DimReseller` during the ETL phase, rather than resolved through a `GeographyKey` foreign key. Since a flat, denormalized star schema is the preferred design for Tabular models (per Kimball methodology), `DimGeography` was deemed redundant and removed from the Tabular model (`Delete from Model`) — it remains untouched in the underlying DW.

## Relationships

- All fact-to-dimension relationships were verified as complete, including `DimSalesTerritory` and `DimPromotion` on `FactInternetSales`.
- Each fact table has three relationships to `DimDate` (`OrderDateKey`, `DueDateKey`, `ShipDateKey`), of which only `OrderDateKey` is Active; the other two remain Inactive and are available for `USERELATIONSHIP` in DAX when needed.

## Date table configuration

- `DimDate` was marked as the model's official **Date Table**, with `FullDate` set as the Date Column — required for DAX time-intelligence functions to work correctly.
- A `Calendar` hierarchy was created: `Year → Quarter → MonthName → DayOfMonth`.
- `Sort By Column` was configured for `MonthName` (sorted by `MonthNumber`) and `DayName` (sorted by `DayOfWeek`) so calendar ordering displays correctly instead of alphabetically.

## Measures

A dedicated hidden measure table (created via `= ROW("Measure", BLANK())`, hidden from client tools) holds all DAX measures, organized in layers:

- **Base measures:** `Internet Net Revenue`, `Internet Total Sales`, `Internet Total Quantity`, `Internet Order Count`, and the equivalent Reseller measures
- **Combined measures:** `Total Sales (All Channels)`, `Internet Sales PY`, `Reseller Sales PY`
- **Analytical measures (built on the above, avoiding duplicated logic — DRY principle):** `Total Sales PY (All Channels)`, `Internet Sales Share %`, `Reseller Sales Share %`, `Total Sales YoY % (All Channels)`, plus YTD/QTD/MTD variants for both channels

## Bugs found and fixed during this phase

Two significant issues were discovered while validating the model against real data (via an Excel PivotTable connected live to the deployed model):

1. **All `FactInternetSales`/`FactResellerSales` rows collapsed to a single `OrderDateKey`** — caused by `DimDate`'s populated range (through 2016) not covering the actual OLTP order date range (starting 2022); the Lookup Transformation silently fell back to a default key instead of failing. Fixed by extending `DimDate` through 2036, truncating and reloading both fact tables, and resetting their ETL watermarks.
2. **`Internet Sales YoY %` always evaluated to 0** — caused by a well-known DAX pitfall: when a PivotTable groups rows by `Year` and `MonthName` as separate columns of the date table, those filters remain active alongside `SAMEPERIODLASTYEAR`'s date-column filter, producing a contradictory (empty) filter context. Fixed by adding `ALL(DimDate)` to the `CALCULATE` in the `*_Sales_PY` measures.

Both are documented in detail in `TROUBLESHOOTING.md`.

## Outcome

The Tabular model is deployed, all relationships and the date hierarchy are verified, and both base and time-intelligence measures have been validated against real data via a live-connected Excel PivotTable, showing a realistic sales trend across 2022–2024 for both sales channels. Phase 4 is complete.
