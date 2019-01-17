-- Abfrage kleiner Flächen der Originalflächen
SELECT gid, st_transform(the_geom, 25833), st_area(st_transform(the_geom, 25833))
FROM ortsteile
ORDER BY st_area(the_geom)
LIMIT 10

-- Neu Berechnung der Teilflächen
DELETE FROM ortsteile_topo.topo_geom;
INSERT INTO ortsteile_topo.topo_geom (gid, the_geom)
SELECT gid, gdi_cleanpolygon(the_geom, 25833, 0.3, 1)
FROM ortsteile;

-- Abfragen der kleinen Teilfächen
SELECT gid, polygon_id, the_geom, ST_Area(the_geom)
FROM ortsteile_topo.topo_geom
ORDER BY ST_Area(the_geom)
LIMIT 1000

-- Sicht der kleinen Teilflächen mit Geometrie zur Anzeige in QGIS
CREATE OR REPLACE VIEW small_topo_geom as
SELECT gid, polygon_id, the_geom, st_area(the_geom) from ortsteile_topo.topo_geom where st_area(the_geom) < 25000 ORDER BY st_area(the_geom)