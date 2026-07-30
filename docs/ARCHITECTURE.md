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

<!-- Add new entries below this line as new architecture decisions are made. -->
