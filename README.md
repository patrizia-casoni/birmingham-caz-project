# Birmingham Clean Air Zone (CAZ) Impact Study (2018-2025)

Launched in June 2021 following a UK Government legal mandate, the Birmingham Clean Air Zone (CAZ) was implemented to tackle persistent breaches of legal Nitrogen Dioxide (NO2) limits by accelerating the modernisation of the city’s vehicle fleet. This data project analyses the policy's progress between 2018 and 2025 across three core pillars: air quality improvements, fleet compliance, and early signals in respiratory hospital admissions. By engineering a custom 5-Tier Spatial Framework to categorise both monitoring sites and hospital wards based on their distance from the zone, this study evaluates the true environmental and public health impact of the policy. Through a detailed analysis of the volume, type, and compliance of vehicles entering the CAZ, alongside regional air quality and health trends, the project provides a data-driven foundation to understand what should happen next based on the evidence observed so far.

## Tech Stack

* **Database & Architecture:** PostgreSQL, DBeaver, Star Schema Data Modelling
* **Geospatial Analysis:** PostGIS, QGIS
* **Business Intelligence:** Power BI, Icon Map Pro
* **Languages:** SQL, DAX
* **Version Control:** Git, GitHub

## Repository Structure

* **`01_database_setup/`**: Contains the foundational SQL scripts to build and populate the PostgreSQL database.
  * **`01_table_creations/`**: Scripts defining the database schema with strict constraints (Primary/Foreign Keys, NOT NULL). Includes staging for non-ISO datetime formats and PostGIS configurations to translate lat/long coordinates into planar meter projections and flatten complex geometries (CAZ polygon and 69 wards) for Power BI.
  * **`02_data_import/`**: Systematically loads raw CSV files (including 8 distinct NO2 datasets, traffic, and hospitalisations) into the database, strictly loading dimension tables before fact tables to enforce referential integrity.
  * **`03_star_schema/`**: Establishes the core data model by creating conformed dimension tables (`dim_caz_tiers` and `dim_years`). Links monitoring sites and wards to specific spatial tiers, and connects all fact tables to unified calendar and fiscal timelines.
 
  * * **`02_eda_and_diagnostics/`**: Houses the comprehensive Exploratory Data Analysis (EDA) used to identify anomalies and establish strict data cleaning rules prior to analysis.
  * **`01_data_quality_diagnostics.sql`**: A detailed diagnostic script executing in-depth validation checks across all core datasets:
    * **Metadata & Spatial Integrity:** Validates ID/name uniqueness for monitoring sites and wards, and confirms all latitude/longitude coordinates fall strictly within Birmingham city bounds. Checks chronological logic (e.g., decommission dates).
    * **NO2 Sensor Validation & Annualisation Logic:** Detects anomalous readings (extremes >500, or negative values classified as minor drift vs. severe error). Establishes a strict completeness threshold: flagging site-years as valid (≥9 months with 75% valid data), requiring annualisation (3–8 months), or requiring exclusion (<3 months).
    * **Traffic & Health Profiling:** Runs descriptive statistics (min, max, mean, median) on vehicle compliance and hospital admission rates, ensuring no unexpected NULLs, zeros, or temporal gaps.
    * **Temporal Aggregations:** Tests the translation of NO2 data into fiscal years, re-evaluates fiscal annualisation needs, and aggregates valid NO2 profiles by hour, day of the week, and month.
