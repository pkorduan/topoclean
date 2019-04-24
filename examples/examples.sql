/*
  Die in ct_start zur Verfügung stehenden Parameter
  schema_name Name des Schemas in dem die Datentabelle liegt.
  table_name Name der Tabelle in dem die Daten liegen.
  id_column Name der Spalte in der die eindeutige Nummerierung der Polygone ist.
  geom_column Name der Spalte in der die Geometrie ist.
  expression_column Name der Spalte über die gefiltert werden soll. Muss man nur angeben, wenn man auch ein expression angibt, sonst NULL
  epsg_code SRS die die korrigierte Geometrie haben soll. Sollte Metrisch sein, wenn die Toleranzen in Metern angegeben werden
  distance_tolerance Maximaler Abstand zwischen benachbarten Punkten in Linien der Polygone
  angle_toleracne Maximaler Winkel zwischen 3 benachbarten Punkten in Linien von Polygonen
  topo_tolerance Toleranz für das Erzeugen der Topology
  area_tolerance Toleranz für das Löschen von inneren Ringen. Ringe mit Flächen kleiner der Toleranz werden gelöscht.
  gap_area_tolerance Toleranz für das Schließen von Lücken zwischen schon berechneten Flächen. Fläche, die kleiner ist als das kleinste Teilpolygon, aber größer als die Lücken zwischen Polygonen.
  prepare_topo Soll die Geometrie vorbereitet werden. False wenn die Geometrie schon gerechnet wurde, z.B. um die Topologie mehrmals nacheinander Rechnen zu können bei Parameter stop_on_error.
  only_prepare_topo True wenn nur die Geometrie vorbereitet und die Topologie nicht berechnet werden soll. 
  expression Ausdruck über den der Datensatz gefiltert werden soll. Nur die passenden Polygone werden dann bereinigt.
  debug boolean True wenn Debug-Meldungen als Notice erzeugt werden sollen.
  stop_on_error True wenn das Script bei einem Fehler stoppen soll.
*/

-- Nur Prepare
SELECT gdi_PreparePolygonTopo('ortsteile_topo', 'public', 'ortsteile', 'gid', 'the_geom', 'gid', 'IN (3, 243, 1473, 2271, 2816)', 25833, 0.3, 6, 0.2, 1, true, TRUE)

-- 5 nebeneinander liegende Flächen
SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'gid', 25833, 0.3, 6, 0.2, 1, 25000, true, FALSE, 'IN (3, 243, 1473, 2271, 2816)', FALSE, TRUE);

-- Ein ganze Gemeinde
SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'gvb_schl', 25833, 0.3, 6, 0.2, 1, 25000, true, FALSE, '= ' || quote_literal('130745458'), false, TRUE);

-- Ein ganzer Landkreis
SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'krs_schl', 25833, 0.3, 6, 0.2, 1, 25000, true, FALSE, '= ' || quote_literal('13074'), false, FALSE);

-- Ein ganzer Landkreis nur Vorbereitung
SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'krs_schl', 25833, 0.3, 6, 0.2, 1, 25000, true, TRUE, '= ' || quote_literal('13074'), false, true);

-- Der gesamte Datensatz
SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', NULL, 25833, 0.2, 6, 0.3, 1, 25000, true, FALSE, NULL, false, true);

-- Ausführung auf Konsole im Hintergrund
psql -U postgres -c "SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'gid', 25833, 0.3, 6, 0.2, 1, 25000, true, FALSE, 'IN (3, 243, 1473, 2271, 2816)', FALSE, TRUE);" topo_test
nohup psql -U postgres -c "SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'krs_schl', 25833, 0.3, 6, 0.2, 1, 25000, true, FALSE, '= ' || quote_literal('13074'), false, FALSE);" topo_test > ortsteile.log 2> ortsteile.err &
nohup psql -U postgres -c "SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', NULL, 25833, 0.2, 6, 0.3, 1, 25000, true, FALSE, NULL, false, true);" topo_test > ortsteile.log 2> ortsteile.err &

-- Ausführen mit Scripten
./ct_loop.sh public ortsteile gid the_geom gid 25833 0.3 6 0.3 1 25000 true false "gid in (1026, 1593, 2786, 1161, 1058, 460)" true false
nohup ./ct_start.sh public ortsteile gid the_geom gid 25833 0.3 6 0.3 1 25000 true false "gid in (1026, 1593, 2786, 1161, 1058, 460, 2785, 2849, 774, 2784)" true false > cleantopo.msg 2> cleantopo.err &
nohup ./ct_loop.sh public ortsteile gid the_geom gid 25833 0.3 6 0.3 1 25000 true false "krs = 13071" true false > cleantopo.msg 2> cleantopo.err &

-- Abfrage der SQL-Statements
SELECT sql || ';' FROM sql_logs;

select polygon_id from ortsteile_topo.topo_geom order by polygon_id

----------------------------------------------
-- Query missing corrected geometries
SELECT
  o.gid,
  t.polygon_id
FROM
  ortsteile o JOIN
  ortsteile_topo.topo_geom t ON o.gid = t.gid
WHERE
  o.the_geom_topo_corrected IS NULL;

2323
2457
509
264
2898
3832
3762
417
78
1422
808
3774
2224
97
156
1423

-- Add a single polygon to topology
SELECT gdi_addToTopo('ortsteile_topo', 'the_geom', 0.1, 1, 1550, 0, 1, true);

-- Equivalent to addToTopo is
UPDATE ortsteile_topo.topo_geom
SET the_geom_topo = topology.toTopoGeom(the_geom, 'ortsteile_topo', 1, 0.1)
WHERE polygon_id = 1550
SELECT gdi_CleanPolygonTopo('ortsteile_topo', 'ortsteile_topo', 'topo_geom', 'the_geom_topo',1 , 1550, false);
SELECT gdi_RemoveTopoOverlaps('ortsteile_topo', 'ortsteile_topo', 'topo_geom', 'polygon_id', 'the_geom', 'the_geom_topo');
SELECT gdi_RemoveNodesBetweenEdges('ortsteile_topo');

-- In both cases do after addToTopo
SELECT gdi_CloseTopoGaps('ortsteile_topo', 'ortsteile_topo', 'topo_geom', 'the_geom_topo', 17000);
SELECT gdi_RemoveNodesBetweenEdges('ortsteile_topo', true);

-- and update corrected Geometries
UPDATE
  public.ortsteile AS alt
SET
  the_geom_topo_corrected = neu.geom
FROM
  (
    SELECT
      id,
      ST_Multi(ST_Union(geom)) AS geom
    FROM
      (
        SELECT
          gid AS id,
          topology.ST_GetFaceGeometry(
            'ortsteile_topo',
            (topology.GetTopoGeomElements(the_geom_topo))[1]
          ) AS geom
        FROM
          ortsteile_topo.topo_geom
        WHERE
          true
      ) foo
    GROUP BY
      id
  ) neu
WHERE
  alt.gid = neu.id
  
  