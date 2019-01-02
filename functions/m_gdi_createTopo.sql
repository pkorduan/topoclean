-- DROP FUNCTION public.gdi_createtopo(character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean, boolean, character varying, boolean, boolean);
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
    debug boolean,
    stop_on_error BOOLEAN
)
  RETURNS INTEGER AS
$BODY$
  DECLARE
    t integer = 0;
    f integer = 0;
    f_before INTEGER;
    sql text;
    polygon RECORD;
    topo_name CHARACTER VARYING = table_name || '_topo';
    start_time timestamptz;
    delta_time double precision;
    expression_where CHARACTER VARYING = '';
    msg text;
    result integer;
  BEGIN
    RAISE NOTICE 'Starte create_topo: %', clock_timestamp();
    IF prepare_topo THEN
      -- Prepare the polygon topology
      IF debug THEN RAISE NOTICE 'Prepare Topology'; END IF;
      EXECUTE FORMAT('
        SELECT gdi_PreparePolygonTopo(
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
      delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
      IF true THEN RAISE NOTICE '- % ms Duration of gdi_PreparePolygonTopo', lpad(round(delta_time)::text, 6, ' '); END IF;
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
      PERFORM gdi_logsql('CreateTopo', msg, sql);

      FOR polygon IN EXECUTE sql LOOP
        IF debug THEN RAISE NOTICE 'Create TopGeom for object % polygon %', polygon.object_id, polygon.id; END IF;
        t = t + 1;
        f_before = f;
        EXECUTE FORMAT('
          SELECT gdi_addToTopo(
            %1$L, %2$L, %3$s, %4$s, %5$s, %6$s, %7$s, %8$L
          )',
          topo_name, geom_column, topo_tolerance, area_tolerance, polygon.id, f, 1, debug
        )
        INTO f;
        if f > f_before AND stop_on_error THEN
          EXIT;
        END IF;
      END LOOP;

      BEGIN
        start_time = clock_timestamp();
        msg = 'Close Gaps.';
        sql = 'SELECT gdi_CloseTopoGaps(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'')';
        PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF debug THEN RAISE NOTICE '- % ms Duration of gdi_CloseTopoGaps', lpad(round(delta_time)::text, 6, ' '); END IF;

        start_time = clock_timestamp();
        msg = 'Nose Remove between edges.';
        sql = 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
        PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF true THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

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

    RAISE NOTICE 'Beende create_topo: %', clock_timestamp();
    RETURN f;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_createtopo(character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean, boolean, character varying, boolean, BOOLEAN) IS 'Erzeugt die Topologie <table_name>_topo der Tabelle <table_name> in der temporären Tabelle <table_name>_topo mit einer Toleranz von <tolerance> für alle Geometrie aus Spalte <geom_column>, die der Bedingung <expression> genügen. Ist <prepare_topo> false, wird PreparePolygonTopo nicht ausgeführt. Ist <only_prepare_topo> true wird nur die Topologie vorbereitet. Die Rückgabe ist die Anzahl von Polygonen, die nicht zur Topologie hinzugefügt werden konnte.';

