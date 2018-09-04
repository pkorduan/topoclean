--DROP FUNCTION IF EXISTS gdi_CreateTopo(character varying, character varying, character varying, character varying, INTEGER, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, character varying, BOOLEAN);
CREATE OR REPLACE FUNCTION gdi_CreateTopo(
  schema_name CHARACTER VARYING,
  table_name character varying,
  id_column CHARACTER VARYING,
  geom_column CHARACTER VARYING,
  epsg_code INTEGER,
  distance_tolerance DOUBLE PRECISION,
  angle_toleracne DOUBLE PRECISION,
  topo_tolerance DOUBLE PRECISION,
  area_tolerance DOUBLE PRECISION,
  prepare_topo BOOLEAN,
  expression CHARACTER VARYING,
  debug BOOLEAN
)
RETURNS BOOLEAN AS
$BODY$
  DECLARE
    t integer = 0;
    f integer = 0;
    sql text;
    polygon RECORD;
    topo_name CHARACTER VARYING = table_name || '_topo';
    start_time timestamptz;
    delta_time double precision;
  BEGIN

    IF prepare_topo THEN
      -- Prepare the polygon topology
      IF debug THEN RAISE NOTICE 'Prepare Topology'; END IF;
      EXECUTE 'SELECT gdi_PreparePolygonTopo(''' || topo_name || ''', ''' || schema_name || ''', ''' || table_name || ''', ''' || id_column || ''', ''' || geom_column || ''', ' || epsg_code || ', ' || distance_tolerance || ', ' || angle_toleracne || ', ' || topo_tolerance || ', ' || area_tolerance || ', ''' || expression || ''')';
    END IF;

    -- query polygons
    sql = '
      SELECT
        ' || id_column || ' AS object_id,
        polygon_id AS id
      FROM ' || topo_name || '.topo_geom
      ORDER BY polygon_id
    ';
    IF debug THEN RAISE NOTICE 'Query prepared objects for topo generation with sql: %', sql; END IF;
    FOR polygon IN EXECUTE sql LOOP
      RAISE NOTICE 'Create TopGeom for object % polygon %', polygon.object_id, polygon.id;
      t = t + 1;

      BEGIN
        start_time = clock_timestamp();
        EXECUTE '
          UPDATE ' || topo_name || '.topo_geom
          SET ' || geom_column || '_topo = topology.toTopoGeom(' || geom_column || ', ''' || topo_name || ''', 1, ' || topo_tolerance || ')
          WHERE polygon_id = ' || polygon.id || '
        ';
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF debug THEN RAISE NOTICE '- % ms Duration of toTopoGeom', lpad(round(delta_time)::text, 6, ' '); END IF; 

        start_time = clock_timestamp();
        EXECUTE 'SELECT gdi_CleanPolygonTopo(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ' || area_tolerance || ', ' || polygon.id || ')';
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF debug THEN RAISE NOTICE '- % ms Duration of gdi_CleanPolygonTopo', lpad(round(delta_time)::text, 6, ' '); END IF; 

        BEGIN
          start_time = clock_timestamp();
          EXECUTE 'SELECT gdi_RemoveTopoOverlaps(
            ''' || topo_name || ''',
            ''' || topo_name || ''',
            ''topo_geom'',
            ''polygon_id'',
            ''' || geom_column || ''',
            ''' || geom_column || '_topo''
          )';
          delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
          IF debug THEN RAISE NOTICE '- % ms Duration of gdi_RemoveTopoOverlaps', lpad(round(delta_time)::text, 6, ' '); END IF; 

          start_time = clock_timestamp();
          EXECUTE 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
          delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
          IF debug THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

          BEGIN
            start_time = clock_timestamp();
            EXECUTE 'SELECT gdi_CloseTopoGaps(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'')';
            delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
            IF debug THEN RAISE NOTICE '- % ms Duration of gdi_CloseTopoGaps', lpad(round(delta_time)::text, 6, ' '); END IF;

            start_time = clock_timestamp();
            EXECUTE 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
            delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
            IF debug THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

          EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Closing of Gaps failed: %', SQLERRM;
          END;

        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'Removing of Overlaps failed: %', SQLERRM;
        END;

      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Loading of record polygon_id: % failed: %', polygon.id, SQLERRM;
        f = f + 1;
        EXECUTE '
          UPDATE ' || topo_name || '.topo_geom
          SET err_msg = ''' || SQLERRM || '''
          WHERE polygon_id = ' || polygon.id || '
        ';
      END;

    END LOOP;

    RAISE NOTICE '% Polygons added to Topology % failed.', t, f;

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der gelöschten Topologieüberlappungen'',
        (SELECT Round(Sum(ST_Area(face_geom))) FROM ' || topo_name || '.removed_overlaps),
        ''m2''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der gefüllten Topologielücken'',
        (SELECT Round(Sum(ST_Area(face_geom))) FROM ' || topo_name || '.filled_gaps),
        ''m2''
      )
    ';

    -- Zurückschreiben der korrigierten Geometrien in die Spalte geom_column_topo_corrected in der Originaltabelle
    RAISE NOTICE 'Rewrite corrected geometry back to the original table: %.% Column: %_topo_corrected', schema_name, table_name , geom_column;
    EXECUTE '
      UPDATE
        ' || schema_name || '.' || table_name || ' AS alt
      SET
        ' || geom_column || '_topo_corrected = neu.geom
      FROM
        (
          SELECT
            id,
            ST_Multi(ST_Union(geom)) AS geom
          FROM
            (
              SELECT ' || id_column || ' AS id, topology.ST_GetFaceGeometry(''' || topo_name || ''', (topology.GetTopoGeomElements(' || geom_column || '_topo))[1]) AS geom FROM ' || topo_name || '.topo_geom
            ) foo
          GROUP BY
            id
        ) neu
      WHERE
        alt.' || id_column || ' = neu.id
    ';

    EXECUTE 'CREATE INDEX ' || table_name || '_' || geom_column || '_topo_corrected_gist ON ' || schema_name || '.' || table_name || ' USING gist(' || geom_column || '_topo_corrected)';

    RAISE NOTICE 'Calculate and log intersections of corrected geometries.';
    EXECUTE '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''nach TopoCorrection'',
        a.gid,
        b.gid,
        ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(a.the_geom_topo_corrected, b.the_geom_topo_corrected))
            ,3
          )
      )
      FROM
        ' || schema_name || '.' || table_name || ' a JOIN
        ' || schema_name || '.' || table_name || ' b ON (
          a.gid > b.gid AND
          ST_Intersects(a.the_geom_topo_corrected, b.the_geom_topo_corrected) AND
          NOT ST_Touches(a.the_geom_topo_corrected, b.the_geom_topo_corrected)
        )
      ORDER BY
        a.gid, b.gid
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der Überlappungen korrigierter Geometrien'',
        COALESCE(
          (
            SELECT Round(Sum(ST_Area(the_geom)))
            FROM ' || topo_name || '.intersections
            WHERE step = ''nach TopoCorrection''
          ),
          0
        ),
        ''m2''
      ), (
        ''Gesamtfläche korrigierter Geometrien'', (
          SELECT Round(Sum(ST_Area(' || geom_column || '_topo_corrected)))/10000
          FROM ' || schema_name || '.' || table_name || '
        ),
        ''ha''
      ), (
        ''Anzahl Flächen nach Korrektur'', (SELECT count(*) FROM ' || schema_name || '.' || table_name || '), ''Stück''
      ), (
        ''Anzahl Stützpunkte hinterher'', (
          SELECT Sum(ST_NPoints(' || geom_column || '_topo_corrected))
          FROM ' || schema_name || '.' || table_name || '
        ),
        ''Stück''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz nach - vor Topo-Korrektur'',
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche korrigierter Geometrien'') -
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach NoseRemove''),
        ''m2''
      )
    ';


    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz gesamt'',
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche korrigierter Geometrien'') -
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche vorher''),
        ''m2''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz Lücken - Überlappungen'',
        (SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Fläche der gefüllten Topologielücken'') -
        (SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Fläche der gelöschten Topologieüberlappungen''),
        ''m2''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Absoluter Betrag der Differenz der Flächendifferenz gesamt / Lücken-Überlappungen'',
        ABS ((SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Flächendifferenz gesamt'') -
        (SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Flächendifferenz Lücken - Überlappungen'')),
        ''m2''
      )
    ';

    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION gdi_CreateTopo(character varying, character varying, character varying, character varying, INTEGER, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, character varying, BOOLEAN) IS 'Erzeugt die Topologie <table_name>_topo der Tabelle <table_name> in der temporären Tabelle <table_name>_topo mit einer Toleranz von <tolerance> für alle Geometrie aus Spalte <geom_column>, die der Bedingung <expression> genügen. Ist <prepare_topo> false, wird PreparePolygonTopo nicht ausgeführt.';
-- nohup psql -U kvwmap -c "SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 25833, 0.1, 0.01, 0.001, 1, true, 'the_geom && ST_MakeBox2D(ST_MakePoint(235943.561, 5890641.864), ST_MakePoint(300755.045, 5953515.785))', false)" topo_test > ortsteile.log 2> ortsteile.err &

--SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 25833, 0.2, 0.01, 0.01, 1, true, 'the_geom && ST_SetSrid(ST_MakeBox2D(ST_MakePoint(11.28043, 53.41997), ST_MakePoint(11.52070, 53.64125)), 4326)', true)