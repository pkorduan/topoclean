-- DROP FUNCTION public.gdi_createtopo(character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean, boolean, character varying, boolean);

CREATE OR REPLACE FUNCTION public.gdi_createtopo(
    schema_name character varying,
    table_name character varying,
    id_column character varying,
    geom_column character varying,
    expression_column character varying,
    epsg_code integer,
    distance_tolerance double precision,
    angle_toleracne double precision,
    topo_tolerance double precision,
    area_tolerance double precision,
    prepare_topo boolean,
    only_prepare_topo boolean,
    expression character varying,
    debug boolean)
  RETURNS boolean AS
$BODY$
  DECLARE
    t integer = 0;
    f integer = 0;
    sql text;
    polygon RECORD;
    topo_name CHARACTER VARYING = table_name || '_topo';
    start_time timestamptz;
    delta_time double precision;
    expression_where CHARACTER VARYING = '';
    msg text;
  BEGIN
		RAISE NOTICE 'Starte create_topo: %', clock_timestamp();
    IF prepare_topo THEN
      -- Prepare the polygon topology
      IF debug THEN RAISE NOTICE 'Prepare Topology'; END IF;
      EXECUTE FORMAT('
				SELECT
					gdi_PreparePolygonTopo(
						%1$L,
						%2$L,
						%3$L,
						%4$L,
						%5$L,
						%6$L,
						%7$L,
						%8$s,
						%9$s,
						%10$s,
						%11$s,
						%12$s,
						%13$L
					)',
				topo_name, schema_name, table_name, id_column, geom_column, expression_column, expression, epsg_code, distance_tolerance, angle_toleracne, topo_tolerance, area_tolerance, debug
			);
    END IF;

    IF expression IS NOT NULL THEN
      expression_where = 'WHERE ' || expression_column || ' ' || expression;
    END IF;

    RAISE NOTICE 'only prepare topo: %', only_prepare_topo;
    IF NOT only_prepare_topo THEN
      -- query polygons
      msg = 'Query prepared objects for topo generation.';
      sql = '
        SELECT
          ' || id_column || ' AS object_id,
          polygon_id AS id
        FROM
          ' || topo_name || '.topo_geom '
        || expression_where || '
        ORDER BY polygon_id
      ';
      IF debug THEN RAISE NOTICE '% with sql: %', msg, sql; END IF;
      PERFORM logsql('CreateTopo', msg, sql);

      FOR polygon IN EXECUTE sql LOOP
        RAISE NOTICE 'Create TopGeom for object % polygon %', polygon.object_id, polygon.id;
        t = t + 1;

        BEGIN
          start_time = clock_timestamp();
          msg = 'Add geometry to topology.';
          sql = '
            UPDATE ' || topo_name || '.topo_geom
            SET ' || geom_column || '_topo = topology.toTopoGeom(' || geom_column || ', ''' || topo_name || ''', 1, ' || topo_tolerance || ')
            WHERE polygon_id = ' || polygon.id || '
          ';
          RAISE NOTICE 'Create TopoGeom with sql: %', sql;
          PERFORM logsql('CreateTopo', msg, sql); EXECUTE sql;

          delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
          IF debug THEN RAISE NOTICE '- % ms Duration of toTopoGeom', lpad(round(delta_time)::text, 6, ' '); END IF; 

          start_time = clock_timestamp();
          msg = 'Clean Topo.';
          sql = 'SELECT gdi_CleanPolygonTopo(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ' || area_tolerance || ', ' || polygon.id || ', ' || debug || ')';
          PERFORM logsql('CreateTopo', msg, sql); EXECUTE sql;
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
            msg = 'Remove nodes between edges';
            sql = 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
            PERFORM logsql('CreateTopo', msg, sql); EXECUTE sql;
            delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
            IF debug THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

          EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Removing of Overlaps failed: %', SQLERRM;
          END;

        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'Loading of record polygon_id: % failed: %', polygon.id, SQLERRM;
          f = f + 1;
          msg = 'Write err_msg.';
          sql = '
            UPDATE ' || topo_name || '.topo_geom
            SET err_msg = ''' || SQLERRM || '''
            WHERE polygon_id = ' || polygon.id || '
          ';
          PERFORM logsql('CreateTopo', msg, sql); EXECUTE sql;
          --EXIT;
        END;

      END LOOP;

      BEGIN
        start_time = clock_timestamp();
        msg = 'Close Gaps.';
        sql = 'SELECT gdi_CloseTopoGaps(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'')';
        PERFORM logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF debug THEN RAISE NOTICE '- % ms Duration of gdi_CloseTopoGaps', lpad(round(delta_time)::text, 6, ' '); END IF;

        start_time = clock_timestamp();
        msg = 'Nose Remove between edges.';
        sql = 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
        PERFORM logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF debug THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Closing of Gaps failed: %', SQLERRM;
      END;

    END IF;
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

		RAISE NOTICE 'Bende create_topo: %', clock_timestamp();
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_createtopo(character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean, boolean, character varying, boolean) IS 'Erzeugt die Topologie <table_name>_topo der Tabelle <table_name> in der temporären Tabelle <table_name>_topo mit einer Toleranz von <tolerance> für alle Geometrie aus Spalte <geom_column>, die der Bedingung <expression> genügen. Ist <prepare_topo> false, wird PreparePolygonTopo nicht ausgeführt.';
-- SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'gid', 25833, 0.2, 3, 0.2, 1, true, FALSE, 'IN (2816, 243, 3, 1473, 2271)', false);
-- SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 'gvb_schl', 25833, 0.2, 3, 0.2, 1, true, FALSE, '= ' || quote_literal('130745453'), false);

-- nohup psql -U kvwmap -c "SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 25833, 0.1, 0.01, 0.001, 1, true, 'the_geom && ST_MakeBox2D(ST_MakePoint(235943.561, 5890641.864), ST_MakePoint(300755.045, 5953515.785))', false)" topo_test > ortsteile.log 2> ortsteile.err &

--SELECT gdi_CreateTopo('public', 'ortsteile', 'gid', 'the_geom', 25833, 0.2, 0.01, 0.01, 1, true, 'the_geom && ST_SetSrid(ST_MakeBox2D(ST_MakePoint(11.28043, 53.41997), ST_MakePoint(11.52070, 53.64125)), 4326)', true)