# AdventureWorks — End-to-End Data Warehouse & BI Project

> 🚧 **Work in progress.** This repository is being built incrementally, phase by phase.
> A complete architecture overview, setup instructions, and screenshots will be added
> once the project is finished (see roadmap below).

## Overview

An end-to-end Business Intelligence project built on the **AdventureWorks2025** OLTP sample
database, covering the full pipeline from source system analysis to an interactive dashboard:

**SQL Server (source) → SSIS (ETL) → SQL Server Data Warehouse → SSAS Tabular (semantic model) → Power BI (reporting)**

Unlike a generic AdventureWorks walkthrough, this project designs its own Data Warehouse from
scratch (rather than using the pre-built `AdventureWorksDW` sample), with an explicit business
scenario, a documented star schema design, SCD Type 2 dimensions, incremental loads, data quality
checks, and a real troubleshooting log.

## Business Scenario

AdventureWorks sales management wants a Data Warehouse that can:
- Analyze Internet Sales (direct/individual customers) and Reseller Sales (store/B2B) separately
  and comparably
- Track sales trends over time by product, territory, and customer
- Support Year-over-Year comparisons
- Update incrementally rather than via full reload

## Project Roadmap

| Phase | Description | Status |
|---|---|---|
| 0 | Source System Analysis | ✅ Done — [`docs/Phase0_Source_System_Analysis.pdf`](docs/Phase0_Source_System_Analysis.pdf) |
| 1 | Data Warehouse schema design (DDL) | ✅ Done — [`sql/`](sql/) |
| 2 | SSIS packages (ETL) | 🔄 In progress — [`ssis/`](ssis/) |
| 3 | Data quality & ETL testing | ⬜ Not started |
| 4 | SSAS Tabular model | ⬜ Not started |
| 5 | Power BI dashboard | ⬜ Not started |
| 6 | Final documentation | ⬜ Not started |
| 7 | Automation / deployment (optional) | ⬜ Not started |

## Repository Structure

```
/docs      → architecture decisions, source system analysis, troubleshooting log
/sql       → DDL scripts, standalone T-SQL used by SSIS Execute SQL Tasks
  /migrations → incremental ALTER scripts applied after the DW was already created
/ssis      → Integration Services project (.dtsx packages)
/ssas      → Tabular model project
/powerbi   → .pbix report file(s)
```

## Tech Stack

- SQL Server 2025 (source: AdventureWorks2025, target: AdventureWorksDW_Custom)
- SQL Server Integration Services (SSIS)
- SQL Server Analysis Services — Tabular mode (SSAS)
- Power BI Desktop

## Documentation

- [Phase 0 — Source System Analysis](docs/Phase0_Source_System_Analysis.pdf)
- [Architecture Decisions](docs/ARCHITECTURE.md)
- [Challenges & Lessons Learned](docs/TROUBLESHOOTING.md)

---

*A full architecture diagram, star schema design rationale, and setup guide will replace this
README once the project reaches Phase 6.*
