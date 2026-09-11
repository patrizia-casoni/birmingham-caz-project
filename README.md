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
* **`02_eda_and_diagnostics/`**: Diagnostic queries to validate spatial boundaries, sensor accuracy, and establish strict data completeness rules for annualisation.
* **`03_data_cleaning_and_staging/`**: Scripts to clean anomalies, impute unrecognised vehicle types, and process NO2 annualisations.
* **`04_analytical_views/`**: The final, optimised SQL views feeding directly into Power BI, including unified spatial datasets.
* **`05_power_bi_dashboards/`**: The final `.pbix` interactive dashboard file.
