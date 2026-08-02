# Architecture Decisions

A running log of design decisions made *after* Phase 0 (which already covers the star schema design,
grain, and conformed dimensions — see
[`docs/Phase0_Source_System_Analysis.pdf`](Phase0_Source_System_Analysis.pdf)). This file covers
implementation-level decisions made while building the ETL, semantic model, and reports — the "why"
behind choices that aren't obvious just from reading the code.

---

## 1. Manual Lookup + Conditional Split instead of the built-in SCD component

**Phase:** 2 — SSIS
**Decision:** all dimension loads (both Type 1 and Type 2) are built manually with a Lookup
transformation feeding Insert/Update paths, rather than using SSIS's built-in **Slowly Changing
Dimension** wizard component.

**Reasoning:**
- **Performance:** the SCD wizard generates row-by-row `OLE DB Command` updates behind the scenes
  instead of set-based/batch updates. Fine for a handful of rows (e.g. `DimSalesTerritory`), but not
  acceptable once `DimProduct` or `DimCustomer` grow into the thousands of rows.
- **Transparency:** the wizard is a black box — it auto-generates a set of hidden components that are
  awkward to inspect or modify without re-running the wizard from scratch. A manual Lookup pipeline
  makes every step visible and independently editable.
- **Maintainability:** the wizard snapshots dimension metadata at build time; adding or removing a
  column later means re-running the whole wizard. A manual pipeline just needs the relevant component
  updated.
- **Consistency:** Type 2 dimensions (`DimProduct`, `DimCustomer`) need explicit control over
  `StartDate` / `EndDate` / `IsCurrent`, which the wizard supports but abstracts away. Using the same
  manual pattern for both Type 1 and Type 2 dimensions keeps one consistent approach across the whole
  project instead of mixing wizard-based and manual packages.

---

## 2. Hybrid SCD (Type 1 + Type 2 columns within DimCustomer)

**Phase:** 2 — SSIS, `Package_DimCustomer`
**Decision:** not every column in `DimCustomer` is versioned as Type 2. Columns are split:
- **Type 1 (overwrite in place, no new row):** `FirstName`, `LastName`, `FullName`, `EmailAddress`
- **Type 2 (new row + close old row):** `City`, `StateProvinceName`, `CountryRegionName`, `PostalCode`

**Reasoning:**
The test for Type 1 vs. Type 2 per column is whether the historical value matters for reporting.
A name correction or typo fix has no analytical meaning — no report needs to know a customer used to
be spelled differently. Geography, on the other hand, directly affects historically accurate
territory/region analysis: if a customer relocated, sales made before the move should still be
attributed to their location *at the time of the sale*, not their current one. Treating every column
as Type 2 would create a new dimension row (and inflate the table) for a harmless name correction,
while treating every column as Type 1 would silently corrupt historical geography-based analysis.
This same per-column Type 1/Type 2 split is used in Microsoft's own `AdventureWorksDW` sample.

**Implementation impact:** the Conditional Split in `Package_DimCustomer` has two real outputs instead
of one — `Type2Changed` (any geography column differs) and `Type1OnlyChanged` (only name/email differ,
evaluated after the Type2 check) — routed to two different destinations. See the package build notes
for the exact flow.

---

## 3. Allocating header-level Tax and Freight down to the line-item grain

**Phase:** 2 — SSIS, `Package_FactInternetSales` / `Package_FactResellerSales`
**Decision:** `TaxAmt` and `Freight` are only recorded at the **order header** level in OLTP
(`Sales.SalesOrderHeader`), not per line item. Since the fact grain is one row per line item (per
Phase 0), each line's share of tax and freight is calculated proportionally to its share of the
order's subtotal:

```sql
LineTaxAmt  = Header.TaxAmt  * (LineTotal / NULLIF(Header.SubTotal, 0))
LineFreight = Header.Freight * (LineTotal / NULLIF(Header.SubTotal, 0))
```

`NULLIF(SubTotal, 0)` guards against a divide-by-zero on the rare order with a zero subtotal.

**Reasoning:**
This is a standard data warehousing technique called **allocation** — distributing a value that's only
known at a coarser grain down to a finer one, using a reasonable proportional basis (here, each line's
share of the order total). The alternative — storing tax/freight only on one arbitrary line, or
duplicating the full header amount on every line — would either lose information or massively overstate
totals when the fact is aggregated (e.g. `SUM(Freight)` would multiply-count the same shipping charge
once per line item on multi-line orders). Allocating proportionally keeps `SUM(LineTotal)`,
`SUM(TaxAmt)`, and `SUM(Freight)` all consistent with the original order-level totals when rolled back
up.

---

## 4. No staging database/tables

**Phase:** 2 — SSIS (all packages)
**Decision:** this project reads directly from `AdventureWorks2025` (OLTP) into each Data Flow's
Lookup/Transform chain and writes straight to the DW tables — there is no intermediate staging
database or staging tables holding raw, untransformed data.

**Reasoning:**
A staging layer earns its complexity under conditions this project doesn't have:
- **Multiple heterogeneous sources** (e.g. SQL Server + a CSV export + an API) that need to be
  normalized to a common shape before being combined — this project has exactly one source database.
- **Very high volume**, where reading directly from the operational system during ETL would put
  unacceptable load on it — the largest source table here (`Sales.SalesOrderDetail`) is ~121K rows,
  well within what a direct read handles comfortably.
- **Multi-step transforms** where an intermediate result needs to be persisted and re-used, or where
  **restart-ability** matters (resuming a failed load from a saved raw snapshot instead of re-querying
  a source that may no longer reflect the same state).
- **Auditing raw data** independently of what the transform logic did to it.

None of these apply at AdventureWorks' scale with a single source and single-step Lookup-based
transforms, so a staging layer would add engineering overhead without a corresponding benefit
(over-engineering). This is a deliberate omission, not an oversight — the trade-offs above are the
threshold that would justify introducing one if the project's scale or source count ever changed.

---

## 5. Fact packages truncate-and-reload on every run (interim, until Phase 3)

**Phase:** 2 — SSIS, `Package_FactInternetSales` / `Package_FactResellerSales`
**Decision:** each fact package runs `TRUNCATE TABLE` on its target fact table (via an Execute SQL
Task) immediately before its Data Flow Task, so every run fully reloads the table from scratch.

**Reasoning:**
Neither fact package has incremental-extraction logic yet — every run reads the full
`Sales.SalesOrderDetail` / `Sales.SalesOrderHeader` join from OLTP. Without clearing the table first,
re-running the package (e.g. via `Package_Master`, or just re-testing) throws a `PRIMARY KEY` violation
on `(SalesOrderNumber, SalesOrderLineNumber)` for every row already loaded. `TRUNCATE` is safe here
(unlike the `DimDate` situation — see Troubleshooting entry #1) because no other table holds a
`FOREIGN KEY` reference *to* either fact table; they're leaf tables in the schema.

**Status: intentionally temporary.** This satisfies correctness for now, but not the Phase 0 business
scenario's actual requirement ("update incrementally, not via full reload") — a full reload of ~121K+
rows on every run doesn't scale and defeats the purpose of incremental loading. The "Planned — not yet
implemented" section below already tracks the real fix: filtering the OLE DB Source query with a
`ModifiedDate`-based watermark so only new/changed orders are extracted, at which point this
truncate-and-reload step will be replaced by an incremental upsert.

---

<!-- Add new entries below this line as new architecture decisions are made. -->

---

## Planned — not yet implemented

Ideas captured during design discussions that belong to a specific upcoming phase. Move each one into
a numbered decision above once it's actually implemented, with the real reasoning and any trade-offs
discovered during the build.

- **Phase 3 — Incremental extraction using `ModifiedDate` as a watermark.**
  Current dimension packages do a full read of the source table on every run and detect changes via
  column-by-column comparison in a Conditional Split (see decision #2). Most AdventureWorks OLTP
  tables (`Production.Product`, `Sales.Customer`, `Sales.SalesOrderHeader`, etc.) already have a
  `ModifiedDate DATETIME` column. A future incremental-extraction pass can filter the OLE DB Source
  query to `WHERE ModifiedDate > @LastETLRunDate`, so only rows actually changed since the last run
  are read and compared — instead of reading the full source table every time. This satisfies the
  Phase 0 business scenario requirement ("update incrementally, not via full reload") more literally
  than the current change-detection-only approach.
  (Note: SQL Server's `timestamp`/`rowversion` type is a separate, unrelated mechanism — an
  auto-incrementing per-row version number, not an actual date/time — that could serve the same
  watermark purpose if a table lacked a `ModifiedDate` column.)
