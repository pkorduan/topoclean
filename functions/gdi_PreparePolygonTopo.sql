--DROP FUNCTION IF EXISTS gdi_PreparePolygonTopo(character varying, character varying, character varying, character varying, character varying, integer, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, CHARACTER VARYING);
CREATE OR REPLACE FUNCTION gdi_PreparePolygonTopo(
  topo_name CHARACTER VARYING,
  schema_name CHARACTER VARYING,
  table_name character varying,
  id_column CHARACTER VARYING,
  geom_column CHARACTER VARYING,
  epsg_code INTEGER,
  distance_tolerance DOUBLE PRECISION,
  angle_tolerance DOUBLE PRECISION,
  topo_tolerance DOUBLE PRECISION,
  area_tolerance DOUBLE PRECISION,
  expression CHARACTER VARYING
)
RETURNS BOOLEAN AS
$BODY$
  DECLARE
    sql text;
    result RECORD;
    debug BOOLEAN = false;
  BEGIN

    -- Prüfe ob ein topo_name angegeben wurde
    IF topo_name = '' OR topo_name IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die Topographie angegeben werden!';
    END IF;

    -- Ersetze schema_name mit public when leer oder NULL und prüfe ob es das Schema gibt
    IF schema_name = '' OR schema_name IS NULL THEN
      schema_name = 'public';
    END IF;
    EXECUTE 'SELECT schema_name FROM information_schema.schemata WHERE schema_name = ''' || schema_name || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Schema % nicht gefunden!', schema_name;
    END IF;

    -- Prüfe ob ein Tabellenname angegeben wurde und ob es die Tabelle in dem Schema gibt
    IF table_name = '' OR table_name IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Tabellenname angegeben werden!';
    END IF;
    EXECUTE 'SELECT table_name from information_schema.tables WHERE table_schema =  ''' || schema_name || ''' AND table_name = ''' || table_name || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Tabelle % im Schema % nicht gefunden!', table_name, schema_name;
    END IF;

    -- Prüfe ob die id Spalte angegeben worden ist und in der Tabelle vorhanden ist
    IF id_column = '' OR id_column IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die ID-Spalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT column_name from information_schema.columns WHERE table_schema =  ''' || schema_name || ''' AND table_name = ''' || table_name || ''' AND column_name = ''' || id_column || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Spalte % in Tabelle % nicht gefunden!', id_column, table_name;
    END IF;

    -- Prüfe ob die geom Spalte angegeben worden, in der Tabelle vorhanden und vom Geometrietyp Polygon oder MultiPolygon ist
    IF geom_column = '' OR geom_column IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die Geometriespalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT type FROM geometry_columns WHERE f_table_schema =  ''' || schema_name || ''' AND f_table_name = ''' || table_name || ''' AND f_geometry_column = ''' || geom_column || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Geometriespalte % in Tabelle % nicht gefunden oder nicht vom Typ geometry!', geom_column, table_name;
    END IF;
    IF Position('POLYGON' IN result.type) = 0 THEN
      RAISE EXCEPTION 'Geometriespalte % in Tabelle % ist nicht vom Typ Polygon oder MultiPolygon!', geom_column, table_name;
    END IF;

    -- Prüfe ob die epsg_code Spalte angegeben worden ist und ob es diesen gibt
    IF epsg_code IS NULL THEN
      RAISE EXCEPTION 'Es muss ein EPSG-Code für die zu korrigierende Geometriespalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT srid FROM spatial_ref_sys WHERE srid = ' || epsg_code INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'EPSG-Code % existiert nicht!', epsg_code;
    END IF;

    -- Prüfe ob die distance-Toleranz angegeben worden ist
    IF distance_tolerance = 0 OR distance_tolerance IS NULL THEN
      RAISE EXCEPTION 'Es muss eine Toleranz angegeben werden für die Löschung von zu eng beieinander liegenden Punkten!';
    END IF;

    -- Prüfe ob die Topo-Toleranz angegeben worden ist
    IF topo_tolerance = 0 OR topo_tolerance IS NULL THEN
      RAISE EXCEPTION 'Es muss eine Toleranz angegeben werden für die Bildung der Topologie!';
    END IF;

    -- drop topology
    IF debug THEN RAISE NOTICE 'Drop Topology: %', topo_name; END IF;
    EXECUTE '
      SELECT topology.DropTopology(''' || topo_name || ''')
      WHERE EXISTS (
        SELECT * FROM topology.topology WHERE name = ''' || topo_name || '''
      )
    ';
    -- create topology
    if debug THEN RAISE NOTICE 'Create Topology: %', topo_name; END IF;
    EXECUTE 'SELECT topology.CreateTopology(''' || topo_name || ''', '|| epsg_code || ', ' || topo_tolerance || ')';

    -- create tables for logging results
    if debug THEN RAISE NOTICE 'Create tables for logging results'; END IF;

    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.intersections';
    EXECUTE '
      CREATE TABLE ' || topo_name || '.intersections (
        step character varying,
        polygon_a_id integer,
        polygon_b_id integer,
        the_geom geometry(MULTIPOLYGON, ' || epsg_code || '),
        CONSTRAINT intersections_pkey PRIMARY KEY (step, polygon_a_id, polygon_b_id)
      )
    ';

    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.removed_spikes';
    EXECUTE '
      CREATE TABLE ' || topo_name || '.removed_spikes (
        id serial,
        polygon_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        CONSTRAINT removed_spikes_pkey PRIMARY KEY (id)
      )
    ';

    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.removed_overlaps';
    EXECUTE '
      CREATE TABLE ' || topo_name || '.removed_overlaps (
        removed_face_id integer,
        from_polygon_id integer,
        for_polygon_id integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT removed_overlaps_pkey PRIMARY KEY (removed_face_id, from_polygon_id, for_polygon_id)
      )
    ';

    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.filled_gaps';
    EXECUTE '
      CREATE TABLE ' || topo_name || '.filled_gaps (
        polygon_id integer,
        face_id integer,
        num_edges integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT filled_gaps_pkey PRIMARY KEY (polygon_id, face_id)
      )
    ';

    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.statistic';
    EXECUTE '
      CREATE TABLE ' || topo_name || '.statistic (
        nr serial,
        key character varying,
        value double precision,
        description text,
        CONSTRAINT statistic_pkey PRIMARY KEY (nr)
      )
    ';

    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.removed_nodes';
    EXECUTE '
      CREATE TABLE ' || topo_name || '.removed_nodes (
        node_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        CONSTRAINT removed_nodes_pkey PRIMARY KEY (node_id)
      )
    ';

    if debug THEN RAISE NOTICE 'Write first 7 statistics data'; END IF;
    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (''Name der Topologie'', NULL, ''' || topo_name || '''),
      (''Ursprüngliche Tabelle'', NULL, '''|| schema_name || '.' || table_name || '''),
      (''Geometriespalte'', NULL, ''' || geom_column || '''),
      (''Distanz Toleranz'', ' || distance_tolerance || ', ''m''),
      (''Angle Toleranz'', ' || angle_tolerance || ', ''m''),
      (''Topology Toleranz'', ' || topo_tolerance || ', ''m''),
      (''Gesamtfläche vorher'', (SELECT Round(Sum(ST_Area(ST_Transform(' || geom_column || ', ' || epsg_code || '))))/10000 FROM ' || schema_name || '.' || table_name || '), ''ha''),
      (''Anzahl Flächen vorher'', (SELECT count(*) FROM ' || schema_name || '.' || table_name || '), ''Stück''),
      (''Anzahl Stützpunkte vorher'', (SELECT Sum(ST_NPoints(' || geom_column || ')) FROM ' || schema_name || '.' || table_name || '), ''Stück'')
    ';
/*
    Das hier fällt erstmal flach, weil die Geometrie vor der Vorverarbeitung noch invalid sein kann und jetzt nur für diese Verschneidung nicht vorab schon mal korrigiert werden soll
    den Aufwand kann man betreiben wenn man an der Statistik interessiert ist wie viel Verschneidungsfäche sich durch die Vorverarbeitung ändert.
    Man müsste die Ausgangsgeometrie noch mal separat zwischenspeichern und indizieren, damit die Verschneidung performant läuft.
    Den Schritt lassen wir erstmal weg.
    RAISE NOTICE 'Calculate Intersections of original geometry in table intersections.';
    EXECUTE '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''vor Polygonaufbereitung'' AS step,
        a.gid AS polygon_a_id,
        b.gid AS polygon_b_id,
        ST_Transform(ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(a.the_geom, b.the_geom))
            ,3
          )
        ), ' || epsg_code || ') AS the_geom
      FROM
        ' || schema_name || '.' || table_name || ' a JOIN
        ' || schema_name || '.' || table_name || ' b ON ST_Intersects(a.the_geom, b.the_geom) AND a.gid > b.gid AND NOT ST_Touches(a.the_geom, b.the_geom)
      ORDER BY
        a.gid, b.gid
    ';
*/
    IF debug THEN RAISE NOTICE 'Drop table topo_geom in topology schema % if exists.', topo_name; END IF;
    -- create working table for topological corrected polygons
    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.topo_geom';
    sql = '
      CREATE TABLE ' || topo_name || '.topo_geom AS
      SELECT
        f.' || id_column || ',
        ST_GeometryN(
          f.geom,
          generate_series(
            1,
            ST_NumGeometries(f.geom)
          )
        ) AS ' || geom_column || ',
        ''''::CHARACTER VARYING AS err_msg
      FROM
        (
          SELECT
            ' || id_column || ',
            gdi_FilterRings(
              ST_SimplifyPreserveTopology(
                ST_CollectionExtract(
                  ST_MakeValid(
                    ST_Transform(
                      ST_GeometryN(
                        ' || geom_column || ',
                        generate_series(
                          1,
                          ST_NumGeometries(' || geom_column || ')
                        )
                      ),
                      ' || epsg_code || '
                    )
                  ),
                  3
                ),
                ' || distance_tolerance || '
              ),
              ' || area_tolerance || '
            ) AS geom
          FROM
            ' || schema_name || '.' || table_name || '
          WHERE ' || expression || '
        ) f
      ORDER BY ' || id_column || '
    ';
    RAISE NOTICE 'Prepare polygons.';
    IF debug THEN RAISE NOTICE 'Create and fill table %.topo_geom with prepared polygons with sql: %', topo_name, sql; END IF;
    EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Add columns polygon_id, %_topo, %_corrected_geom and indexes', table_name, table_name; END IF;
    BEGIN
      EXECUTE 'CREATE INDEX ' || table_name || '_' || geom_column ||'_gist ON ' || schema_name || '.' || table_name || ' USING gist(' || geom_column || ')';
    EXCEPTION
      WHEN duplicate_table
      THEN RAISE NOTICE 'Index: %_%_gist on table: % already exists, skipping!', table_name, geom_column, table_name;
    END;
    EXECUTE 'ALTER TABLE ' || topo_name || '.topo_geom ADD COLUMN polygon_id serial NOT NULL';
    EXECUTE 'ALTER TABLE ' || topo_name || '.topo_geom ADD CONSTRAINT ' || table_name || '_topo_pkey PRIMARY KEY (polygon_id)';
    EXECUTE 'CREATE INDEX topo_geom_' || id_column || '_idx ON ' || topo_name || '.topo_geom USING btree (' || id_column || ')';
    EXECUTE 'CREATE INDEX topo_geom_' || geom_column || '_gist ON ' || topo_name || '.topo_geom USING gist(' || geom_column || ')';
    EXECUTE 'SELECT AddTopoGeometryColumn(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ''Polygon'')';
    IF debug THEN RAISE NOTICE 'Drop column %_topo_corrected if exists!', geom_column; END IF; 
    EXECUTE 'ALTER TABLE ' || schema_name || '.' || table_name || ' DROP COLUMN IF EXISTS ' || geom_column || '_topo_corrected';
    EXECUTE 'SELECT AddGeometryColumn(''' || schema_name || ''', ''' || table_name || ''', ''' || geom_column || '_topo_corrected'', ' || epsg_code || ', ''MultiPolygon'', 2)';

    IF debug THEN RAISE NOTICE 'Calculate intersections after polygon preparation in table intersections'; END IF;
    EXECUTE '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''nach Polygonaufbereitung'',
        a.polygon_id,
        b.polygon_id,
        ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(a.the_geom, b.the_geom))
            ,3
          )
      )
      FROM
        ' || topo_name || '.topo_geom a JOIN
        ' || topo_name || '.topo_geom b ON ST_Intersects(a.the_geom, b.the_geom) AND a.polygon_id > b.polygon_id AND NOT ST_Touches(a.the_geom, b.the_geom)
      ORDER BY
        a.polygon_id, b.polygon_id
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der Überlappungen nach Polygonaufbereitung'',
        (
          SELECT Round(Sum(ST_Area(the_geom)))
          FROM ' || topo_name || '.intersections
          WHERE step = ''nach Polygonaufbereitung''
        ),
        ''m2''
      ), (
        ''Gesamtfläche nach Polygonaufbereitung'',
        (
          SELECT
            Round(Sum(ST_Area(' || geom_column || ')))/10000
          FROM
            ' || topo_name || '.topo_geom
        ),
        ''ha''
      ), (
        ''Anzahl der Polygone'', (SELECT count(*) FROM ' || topo_name || '.topo_geom), ''Stück'')
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz nach - vor Polygonaufbereitung'',
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach Polygonaufbereitung'') -
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche vorher''),
        ''m2''
      )
    ';

    IF debug THEN RAISE NOTICE 'Do NoseRemove and update topo_geom.'; END IF;
    EXECUTE '
      UPDATE ' || topo_name || '.topo_geom
      SET ' || geom_column || ' = gdi_NoseRemove(''' || topo_name || ''', polygon_id, ' || geom_column || ', ' || angle_tolerance || ', ' || distance_tolerance || ')
    ';

    IF debug THEN RAISE NOTICE 'Calculate Intersection after NoseRemove in table intersections.'; END IF;
    EXECUTE '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''nach NoseRemove'',
        a.polygon_id,
        b.polygon_id,
        ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(a.the_geom, b.the_geom))
            ,3
          )
      )
      FROM
        ' || topo_name || '.topo_geom a JOIN
        ' || topo_name || '.topo_geom b ON ST_Intersects(a.the_geom, b.the_geom) AND a.polygon_id > b.polygon_id AND NOT ST_Touches(a.the_geom, b.the_geom)
      ORDER BY
        a.polygon_id, b.polygon_id
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der Überlappungen nach NoseRemove'',
        (
          SELECT Round(Sum(ST_Area(the_geom)))
          FROM ' || topo_name || '.intersections
          WHERE step = ''nach NoseRemove''
        ),
        ''m2''
      ), (
        ''Gesamtfläche nach NoseRemove'',
        (
          SELECT
            Round(Sum(ST_Area(' || geom_column || ')))/10000
          FROM
            ' || topo_name || '.topo_geom
        ),
        ''ha''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz nach - vor NoseRemove'',
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach NoseRemove'') -
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach Polygonaufbereitung''),
        ''m2''
      );
    ';

    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION gdi_preparepolygontopo(character varying, character varying, character varying, character varying, character varying, integer, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, CHARACTER VARYING) IS 'Bereitet die Erzeugung einer Topologie vor in dem die Geometrien der betroffenen Tabelle zunächst in einzelne Polygone zerlegt, transformiert, valide und mit distance_tolerance vereinfacht werden. Die Polygone werden in eine temporäre Tabelle kopiert und dort eine TopGeom Spalte angelegt. Eine vorhandene Topologie und temporäre Tabelle mit gleichem Namen wird vorher gelöscht.';