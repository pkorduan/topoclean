-- DROP FUNCTION public.gdi_preparetopo(character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean);

CREATE OR REPLACE FUNCTION public.gdi_preparetopo(
    topo_name character varying,
    schema_name character varying,
    table_name character varying,
    id_column character varying,
    geom_column character varying,
    expression_column character varying,
    expression character varying,
    epsg_code integer,
    distance_tolerance double precision,
    angle_tolerance double precision,
    topo_tolerance double precision,
    area_tolerance double precision,
    debug boolean)
  RETURNS boolean AS
$BODY$
  DECLARE
    sql text;
    msg text;
    result RECORD;
    rec record;
    expression_select CHARACTER VARYING = '';
    expression_where CHARACTER VARYING = '';
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

    -- CREATE TABLE for logging sql
    EXECUTE 'DROP TABLE IF EXISTS sql_logs';
    sql = '
      CREATE UNLOGGED TABLE sql_logs (
        id serial,
        func character varying,
        step character varying,
        sql text,
        CONSTRAINT sql_log_pkey PRIMARY KEY (id)
      )
    ';
    EXECUTE sql;
    if debug THEN RAISE NOTICE 'CREATE TABLE for logging sql with sql: %', sql; END IF;

    -- drop topology
    IF debug THEN RAISE NOTICE 'Drop Topology: %', topo_name; END IF;
    sql = '
      SELECT topology.DropTopology(''' || topo_name || ''')
      WHERE EXISTS (
        SELECT * FROM topology.topology WHERE name = ''' || topo_name || '''
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    -- create topology
    if debug THEN RAISE NOTICE 'Create Topology: %', topo_name; END IF;
    sql = 'SELECT topology.CreateTopology(''' || topo_name || ''', '|| epsg_code || ', ' || topo_tolerance || ')';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    -- CREATE UNLOGGED TABLEs for logging results
    if debug THEN RAISE NOTICE 'CREATE UNLOGGED TABLEs for logging results'; END IF;
    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.intersections';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.intersections (
        step character varying,
        polygon_a_id integer,
        polygon_b_id integer,
        the_geom geometry(MULTIPOLYGON, ' || epsg_code || '),
        CONSTRAINT intersections_pkey PRIMARY KEY (step, polygon_a_id, polygon_b_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.next';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.next (
        id character varying,
        pid integer
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_spikes';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_spikes (
        id serial,
        polygon_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        CONSTRAINT removed_spikes_pkey PRIMARY KEY (id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_overlaps';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_overlaps (
        removed_face_id integer,
        from_polygon_id integer,
        for_polygon_id integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT removed_overlaps_pkey PRIMARY KEY (removed_face_id, from_polygon_id, for_polygon_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.filled_gaps';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.filled_gaps (
        polygon_id integer,
        face_id integer,
        num_edges integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT filled_gaps_pkey PRIMARY KEY (polygon_id, face_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.statistic';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.statistic (
        nr serial,
        key character varying,
        value double precision,
        description text,
        CONSTRAINT statistic_pkey PRIMARY KEY (nr)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_nodes';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_nodes (
        node_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        err_msg text,
        CONSTRAINT removed_nodes_pkey PRIMARY KEY (node_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    IF expression_column IS NOT NULL THEN
      IF expression_column NOT IN (id_column, geom_column, 'err_msg') THEN
        expression_select = expression_column || ' integer,';
      END IF;
      expression_where = ' WHERE ' || expression;
    END IF;

    if debug THEN RAISE NOTICE 'Write first 9 statistics data'; END IF;
    sql = '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (''Name der Topologie'', NULL, ''' || topo_name || '''),
      (''Ursprüngliche Tabelle'', NULL, '''|| schema_name || '.' || table_name || '''),
      (''Geometriespalte'', NULL, ''' || geom_column || '''),
      (''Distanz Toleranz'', ' || distance_tolerance || ', ''m''),
      (''Angle Toleranz'', ' || angle_tolerance || ', ''m''),
      (''Topology Toleranz'', ' || topo_tolerance || ', ''m'')
      , (''Gesamtfläche vorher'', (SELECT Round(Sum(ST_Area(ST_Transform(' || geom_column || ', ' || epsg_code || '))))/10000 FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''ha'')
      , (''Anzahl Flächen vorher'', (SELECT count(*) FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''Stück'')
      , (''Anzahl Stützpunkte vorher'', (SELECT Sum(ST_NPoints(' || geom_column || ')) FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''Stück'')
    ';
    PERFORM gdi_logsql('preparetopo', 'Insert Statistic', sql); EXECUTE sql;

    sql = FORMAT ('
      CREATE UNLOGGED TABLE %1$I.topo_geom (
        %2$I integer,
        %3$s
        %4$I geometry(' || quote_literal('POLYGON') || ', %7$s),
        err_msg text
      )
      ',
      topo_name, id_column, expression_select, geom_column, schema_name, table_name, epsg_code
    );
    IF true THEN RAISE NOTICE 'Create table %.topo_geom for prepared polygons with sql: %', topo_name, sql; END IF;
    PERFORM gdi_logsql('preparetopo', 'Create topo geom table.', sql); EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Add columns polygon_id, %_topo, %_corrected_geom and indexes', table_name, table_name; END IF;
    BEGIN
      sql = 'CREATE INDEX ' || table_name || '_' || geom_column ||'_gist ON ' || schema_name || '.' || table_name || ' USING gist(' || geom_column || ')';
      PERFORM gdi_logsql('preparetopo', 'Create gist index.', sql); EXECUTE sql;
    EXCEPTION
      WHEN duplicate_table
      THEN RAISE NOTICE 'Index: %_%_gist on table: % already exists, skipping!', table_name, geom_column, table_name;
    END;
    sql = 'ALTER TABLE ' || topo_name || '.topo_geom ADD COLUMN polygon_id serial NOT NULL';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'ALTER TABLE ' || topo_name || '.topo_geom ADD CONSTRAINT ' || table_name || '_topo_pkey PRIMARY KEY (polygon_id)';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'CREATE INDEX topo_geom_' || id_column || '_idx ON ' || topo_name || '.topo_geom USING btree (' || id_column || ')';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'CREATE INDEX topo_geom_' || geom_column || '_gist ON ' || topo_name || '.topo_geom USING gist(' || geom_column || ')';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'SELECT topology.AddTopoGeometryColumn(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ''Polygon'')';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Replace column %_topo_corrected if exists!', geom_column; END IF; 
    sql = 'ALTER TABLE ' || schema_name || '.' || table_name || ' DROP COLUMN IF EXISTS ' || geom_column || '_topo_corrected';
    PERFORM gdi_logsql('preparetopo', 'Drop column for corrected geom to geometry table.', sql); EXECUTE sql;
    sql = 'SELECT AddGeometryColumn(''' || schema_name || ''', ''' || table_name || ''', ''' || geom_column || '_topo_corrected'', ' || epsg_code || ', ''MultiPolygon'', 2)';
    PERFORM gdi_logsql('preparetopo', 'Add column for corrected geom to geometry table.', sql); EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Replace column %_msg if exists!', geom_column; END IF; 
    sql = 'ALTER TABLE ' || schema_name || '.' || table_name || ' DROP COLUMN IF EXISTS ' || geom_column || '_msg';
    PERFORM gdi_logsql('preparetopo', 'Drop column for msg in geometry table.', sql); EXECUTE sql;
    sql = 'ALTER TABLE ' || schema_name || '.' || table_name || ' ADD COLUMN ' || geom_column || '_msg text';
    PERFORM gdi_logsql('preparetopo', 'Add column for msg in geometry table.', sql); EXECUTE sql;

    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_preparetopo(character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean) IS 'Prüft ob alle Angaben für eine Topologie vorhanden sind und legt eine Leere Topologie an. Hängt eine Spalte für die korrigierte Geometrie und für Fehlermeldungen an die Originaltabelle an. Erzeugt im Topologieschema auch Tabellen für die Abarbeitungsschritte und Statistik. Ist eine gleichnamige Topologie vorhanden wird diese vorher gelöscht.';

