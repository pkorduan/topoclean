# topoclean
PostGIS - Functions to create topologically correct polygons, removing overlaps and filling gaps.

# Functions
## gdi_CreateTopo
Creates a topology of all polygons from a given table, removes overlaps, fill gaps, writes the corrected geometries in a new column and leaf a bunch of statistic data and log table in the topology schema.

### Usage
It takes to following arguments
* schema_name CHARACTER VARYING, origin and target schema
* table_name character varying, origin and target table
* id_column CHARACTER VARYING, name of a unique column in the origin table
* geom_column CHARACTER VARYING, name of the column of the geom that has to be corrected
* epsg_code INTEGER, CRS for the corrected geometry, must be a metric system with unit meter
* distance_tolerance DOUBLE PRECISION, Used for simplification in meter
* angle_toleracne DOUBLE PRECISION, Used for simplification in degree
* topo_tolerance DOUBLE PRECISION, Used as tolerance for the topology creation in meter
* area_tolerance DOUBLE PRECISION, Used to remove small isolated holes, in square meter
* prepare_topo BOOLEAN, false if not prepare the tables before starting the correction
* expression CHARACTER VARYING, Used in SQL WHERE section to select only a part of the data from table

It uses the other functions
* gdi_PreparePolygonTopo
* gdi_NoseRemoveCore
* gdi_NoseRemove
* gdi_RemoveTopoOverlaps
* gdi_ModEdgeHealException
* gdi_CloseTopoGaps
* gdi_CleanPolygonTopo
* gdi_RemoveNodesBetweenEdges

### Installation
* Execute the create statements in the files in sub directory functions in alphabetic order
* File topoClean.sql contain all function create statements in the right order at once

### Example
see in sub directory examples