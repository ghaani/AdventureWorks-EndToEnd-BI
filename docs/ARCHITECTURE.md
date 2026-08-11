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

## 5. Fact packages truncate-and-reload on every run (interim, superseded by Decision #7)

**Phase:** 2 — SSIS, `Package_FactInternetSales` / `Package_FactResellerSales`
**Decision:** each fact package runs `TRUNCATE TABLE` on its target fact table (via an Execute SQL
Task) immediately before its Data Flow Task, so every run fully reloads the table from scratch.

**Reasoning:**
Neither fact package had incremental-extraction logic yet at this point — every run read the full
`Sales.SalesOrderDetail` / `Sales.SalesOrderHeader` join from OLTP. Without clearing the table first,
re-running the package (e.g. via `Package_Master`, or just re-testing) threw a `PRIMARY KEY` violation
on `(SalesOrderNumber, SalesOrderLineNumber)` for every row already loaded. `TRUNCATE` was safe here
(unlike the `DimDate` situation — see Troubleshooting entry #1) because no other table holds a
`FOREIGN KEY` reference *to* either fact table; they're leaf tables in the schema.

**Status: superseded.** Phase 3 (Decision #7 below) replaced this truncate-and-reload approach with
proper watermark-based incremental extraction, satisfying the Phase 0 business scenario requirement
("update incrementally, not via full reload") that this interim approach didn't yet meet. This entry
is kept for the historical record of how the fact packages worked before Phase 3.

---

## 6. Sequential (not parallel) execution of the two fact packages

**Phase:** 2 — SSIS, `Package_Master`
**Decision:** `Execute FactInternetSales` and `Execute FactResellerSales` run one after another (a
Precedence Constraint between them), instead of both starting in parallel after `SEQ_LoadDimensions`
completes.

**Reasoning:**
Architecturally, the two fact loads are independent of each other and could run in parallel — nothing
about the design requires them to be sequential. The decision here is purely a match to the actual
development machine's resources (Intel Core i5-6300U, dual-core, 8 GB RAM). Each fact package runs a
Data Flow with 7–8 full-cache Lookups against ~121K source rows; running both simultaneously meant the
CPU and RAM were shared between two memory- and CPU-heavy Data Flows at once, causing heavy contention
(context switching, possible paging) rather than a real speedup. Running them sequentially removed that
contention and was faster in practice on this hardware, even though it's architecturally "slower" in
theory (no parallelism).

**This is an infrastructure-driven trade-off, not a data or logic constraint.** On a machine with more
cores and RAM, switching back to parallel execution (removing the Precedence Constraint) would very
likely be faster and is a reasonable thing to revisit if the project is ever run on stronger hardware
(e.g. a server, or during SSAS/Power BI development on different infrastructure). Documented here so
the choice isn't mistaken for a hidden dependency between the two fact tables — there isn't one.

**Measured result:** on the development machine, running both fact packages in parallel took ~6
minutes; running them sequentially took ~1 minute for the same full `Package_Master` run — resource
contention wasn't a minor overhead, it was the dominant cost.

---

## 7. Watermark-based incremental extraction, with a Stored Procedure fallback for OLE DB parameter-parsing limits

**Phase:** 3 — SSIS (all dimension and fact packages)
**Decision:** every incrementally-loaded table (8 of the 9 dimensions — all but the static `DimDate`
— plus both fact tables) filters its OLE DB Source query against a stored watermark value
(`ModifiedDate > ?`, or the equivalent header/detail columns for the fact tables), rather than reading
the full source table on every run. The watermark for each package is tracked in an `ETL_Watermark`
table (columns: `PackageName`, `LastExtractDate`) and updated after a successful load.

For most tables, this filter is a plain parameterized `SQL Command` in the OLE DB Source. Two
dimensions — `DimCustomer` and `DimReseller` — combine a CTE with a window function
(`ROW_NUMBER() OVER (...)`) to resolve each customer's/reseller's primary address, which the OLE DB
provider's parameter parser cannot handle (`"Parameters cannot be extracted from the SQL command"`).
For these two only, the query was moved into a Stored Procedure under an `ETL` schema
(`ETL.usp_GetDimCustomerIncremental`, `ETL.usp_GetDimResellerIncremental`), called from the OLE DB
Source as `EXEC ETL.usp_GetDim<Name>Incremental @LastWatermark = ?` — see
[`docs/ETL_STORED_PROCEDURES.md`](ETL_STORED_PROCEDURES.md) for the full procedure definitions.

**Reasoning:**
- This directly satisfies the Phase 0 business scenario requirement ("update incrementally, not via
  full reload") that Decision #5's interim truncate-and-reload approach didn't meet.
- The watermark condition only checks `ModifiedDate` on tables that actually supply an output column
  (a key, attribute, or measure) — join-only/filter-only tables (e.g. `Customer` in the fact queries,
  used solely to route rows between Internet and Reseller sales) are excluded, since their
  `ModifiedDate` has no bearing on whether the output row's content changed.
- The Stored Procedure pattern is applied **reactively, not by default** — only for the two queries
  that actually hit the OLE DB parameter-parsing error. Every other package keeps the simpler
  parameterized `SQL Command` approach, since that's easier to read and modify directly from the SSIS
  Source Editor without opening SSMS.

---

## 8. A single, unified Data Warehouse instead of separate Data Marts

**Phase:** 3–4 (made explicit while designing the SSAS Tabular model, but reflects the DW's structure
since Phase 1)
**Decision:** all dimensions and both fact tables live in one Data Warehouse
(`AdventureWorksDW_Custom`), rather than being split into separate, physically distinct Data Marts
(e.g. an "Internet Sales Data Mart" and a "Reseller Sales Data Mart").

**Reasoning:**
The Phase 0 business scenario explicitly requires comparing Internet Sales and Reseller Sales side by
side — that requirement is much harder to satisfy with separate Data Marts, which tend to drift into
incompatible dimension definitions over time (a classic problem with the "independent Data Mart"
approach). Instead, this project follows Kimball's **Bus Architecture**: a single warehouse where
`DimDate`, `DimProduct`, `DimSalesTerritory`, `DimCurrency`, and `DimPromotion` are **conformed
dimensions** — the exact same table, with the exact same keys, referenced by both fact tables. This
gives the benefit normally associated with Data Marts (a focused, subject-specific view for each sales
channel) without the physical duplication or the risk of the two "views" drifting apart, since there's
only one copy of each shared dimension to maintain.

---

## 9. A single, unified SSAS Tabular model instead of separate models per channel

**Phase:** 4 — SSAS Tabular
**Decision:** one Tabular model (Compatibility Level 1700) contains both `FactInternetSales` and
`FactResellerSales`, sharing the conformed dimensions from Decision #8 — rather than building two
separate Tabular models, one per sales channel.

**Reasoning:** a direct consequence of Decision #8 and the same business requirement (comparing both
channels together). A single model lets one Power BI report query both fact tables through the shared
dimensions in the same visual (e.g. the Executive Overview page's combined revenue trend and channel
split), which two separate models — even if their dimensions were kept in sync — couldn't do without
composite models or duplicated data. **Perspectives** (`Internet Sales`, `Reseller Sales`, `Executive
Overview`) were added on top of the single model to give each audience a focused subset of
tables/measures to browse, without needing separate physical models.

---

## 10. `DimGeography` excluded from the Tabular model

**Phase:** 4 — SSAS Tabular
**Decision:** `DimGeography` (a table in the DW schema from Phase 1) is not imported into the Tabular
model.

**Reasoning:** during Phase 4 model review, `DimGeography` was found to have no relationship to any
other table — an orphaned table. Its intended role (Type 2 geography attributes) had, in practice, been
built as **denormalized columns directly inside `DimCustomer` and `DimReseller`** (`City`,
`StateProvinceName`, `CountryRegionName`) rather than resolved through a `GeographyKey` foreign key —
this was how Decision #2's Type 2 geography columns were actually implemented. Since a flat,
denormalized star schema (not a snowflake) is the preferred shape for a Tabular model, keeping
`DimGeography` unused in the model would only add clutter without a working relationship to justify it.
It was removed from the Tabular model (`Delete from Model`) but left untouched in the underlying DW, in
case a future redesign wants to properly normalize geography behind a `GeographyKey`.

---

## 11. Base/building-block measures instead of duplicated DAX logic

**Phase:** 4–5 — SSAS Tabular / Power BI DAX
**Decision:** every DAX measure is layered: simple **base measures** on raw columns (e.g.
`Internet Net Revenue = SUM(FactInternetSales[LineTotal])`), then **combined measures** built by
referencing those base measures rather than re-deriving the same expression (e.g.
`Total Sales (All Channels) = [Internet Net Revenue] + [Reseller Net Revenue]`), then **analytical
measures** built on top of the combined ones (e.g. `Total Sales PY (All Channels)`,
`Total Sales YoY % (All Channels)`, `Internet Sales Share %`).

**Reasoning:** this follows the DRY (Don't Repeat Yourself) principle applied to DAX. Writing out
`[Internet Net Revenue] + [Reseller Net Revenue]` inline inside every measure that needs "total sales"
means that adding a third sales channel later would require finding and editing every measure that
duplicated that expression — an easy way to introduce a silent, inconsistent bug if one occurrence is
missed. With base/building-block measures, the underlying expression exists in exactly one place;
every dependent measure updates automatically. This also made a real bug fix (see
`TROUBLESHOOTING.md`, entry 9 — the `ALL(DimDate)` fix for `*_Sales_PY`) propagate correctly to every
dependent measure (`*_YoY_%`, `Total Sales YoY % (All Channels)`) without needing to touch them
individually.

---

<!-- Add new entries below this line as new architecture decisions are made. -->

---

## Planned — not yet implemented

Ideas captured during design discussions that belong to a specific upcoming phase. Move each one into
a numbered decision above once it's actually implemented, with the real reasoning and any trade-offs
discovered during the build.

- **Phase 7 — `FullReloadMode` parameter in `Package_Master`.**
  A Boolean package parameter that, when true, truncates every dimension and fact table (except the
  static `DimDate`) and resets every row in `ETL_Watermark` to `1900-01-01` before running the normal
  load sequence — giving the project a documented, repeatable way to rebuild the warehouse from scratch
  (e.g. after a schema change or a bug like the `DimDate` range issue in `TROUBLESHOOTING.md` entry 8),
  instead of the ad-hoc manual `TRUNCATE` + watermark reset used to fix that bug.

- **Phase 9 — SSRS paginated report.**
  A print-ready, paginated report (as opposed to the interactive Power BI dashboard), connecting either
  directly to the DW or to the deployed Tabular model via a DAX/MDX query, reusing the same measures
  already defined in the semantic model rather than re-deriving report logic in SSRS.
