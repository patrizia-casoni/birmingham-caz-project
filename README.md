# Birmingham Clean Air Zone (CAZ) Impact Study (2018-2025)

Launched in June 2021 following a UK Government legal mandate, the Birmingham Clean Air Zone (CAZ) was implemented to tackle persistent breaches of legal Nitrogen Dioxide (NO2) limits by accelerating the modernisation of the city’s vehicle fleet. This data project analyses the policy's progress between 2018 and 2025 across three core pillars: air quality improvements, fleet compliance, and early signals in respiratory hospital admissions. By engineering a custom 5-Tier Spatial Framework to categorise both monitoring sites and hospital wards based on their distance from the zone, this study evaluates the true environmental and public health impact of the policy. Through a detailed analysis of the volume, type, and compliance of vehicles entering the CAZ, alongside regional air quality and health trends, the project provides a data-driven foundation to understand what should happen next based on the evidence observed so far.

## Tech Stack

* **Database & Architecture:** PostgreSQL, DBeaver, Star Schema Data Modelling
* **Geospatial Analysis:** PostGIS, QGIS
* **Business Intelligence:** Power BI, Icon Map Pro
* **Languages:** SQL, DAX
* **Version Control:** Git, GitHub

## Repository Structure

* **`01_database_setup/`**: SQL scripts for building the PostgreSQL star schema, configuring PostGIS, and importing raw CSV/GeoJSON data.
* **`02_eda_and_diagnostics/`**: Diagnostic queries to validate spatial boundaries, sensor accuracy, and establish strict data completeness rules.
* **`03_data_cleaning_and_staging/`**: Scripts to impute unrecognised vehicles, process calendar and fiscal NO2 annualisations, and classify sites and wards into 5 spatial CAZ tiers.
* **`04_analytical_views/`**: The final, optimised SQL views feeding directly into Power BI, including unified spatial datasets.
* **`05_power_bi_dashboards/`**: The final interactive dashboard, saved as a Power BI Project (.pbip) to enable source control and separate the semantic model from the report layout.
* **`data/`**: The raw source files (e.g. CSVs and spatial data) used for the initial ingestion into the PostgreSQL database.

* ## 4. Challenges & Solutions

* **Handling Incomplete Sensor Data & Annualisation:**
  * **The Challenge:** Sensor outages and historical data gaps made raw NO2 averages unreliable and complicated standard data imputation.
  * **The Solution:** Built a strict SQL pipeline that first filtered out severe equipment errors (NO2 < -1.0) before enforcing a 75% monthly completeness rule. Reliable years (9+ valid months) were kept as-is, and unusable years (<3 months) were dropped entirely. For partial years (3–8 months), I engineered a spatial algorithm to dynamically match the incomplete site to its nearest valid background monitor, imputing the missing data by applying a scaling ratio that reflects the normal proportional difference between the two sites.
