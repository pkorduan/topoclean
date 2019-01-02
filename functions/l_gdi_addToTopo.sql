-- DROP FUNCTION public.gdi_addToTopo(CHARACTER VARYING, CHARACTER VARYING, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER, INTEGER, INTEGER, BOOLEAN, BOOLEAN);
CREATE OR REPLACE FUNCTION public.gdi_addToTopo(
  topo_name character varying,
  geom_column character varying,
  topo_tolerance double precision,
  area_tolerance double precision,
  polygon_id INTEGER,
  f INTEGER,
  i INTEGER,
  debug boolean
)
  RETURNS INTEGER AS
$BODY$
  DECLARE
    start_time timestamptz;
    delta_time double precision;
    msg text;
    sql text;
    factor Double PRECISION;
  BEGIN
    IF i < 4 THEN
      factor = CASE
        WHEN i = 2 THEN 1.5
        WHEN i = 3 THEN -1.5
        ELSE 1.0
      END;
      msg = FORMAT('%s. try to add geometry of polygon_id: %s to topology.', i, polygon_id);
      sql = '
        UPDATE ' || topo_name || '.topo_geom
        SET ' || geom_column || '_topo = topology.toTopoGeom(' || geom_column || ', ''' || topo_name || ''', 1, ' || topo_tolerance * factor || ')
        WHERE polygon_id = ' || polygon_id || '
      ';
      IF debug THEN RAISE NOTICE 'Try to create TopoGeom with sql: %', sql; END IF;
      PERFORM gdi_logsql('CreateTopo', msg, sql);

      BEGIN
        start_time = clock_timestamp();
        EXECUTE sql;

        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF true THEN RAISE NOTICE '- % ms Duration of toTopoGeom', lpad(round(delta_time)::text, 6, ' '); END IF; 

        start_time = clock_timestamp();
        msg = 'Clean Topo.';
        sql = 'SELECT gdi_CleanPolygonTopo(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ' || area_tolerance || ', ' || polygon_id || ', ' || debug || ')';
        PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF true THEN RAISE NOTICE '- % ms Duration of gdi_CleanPolygonTopo', lpad(round(delta_time)::text, 6, ' '); END IF; 

        BEGIN
          start_time = clock_timestamp();
          sql = 'SELECT gdi_RemoveTopoOverlaps(
            ''' || topo_name || ''',
            ''' || topo_name || ''',
            ''topo_geom'',
            ''polygon_id'',
            ''' || geom_column || ''',
            ''' || geom_column || '_topo''
          )';
          PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
          delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
          IF true THEN RAISE NOTICE '- % ms Duration of gdi_RemoveTopoOverlaps', lpad(round(delta_time)::text, 6, ' '); END IF; 

          start_time = clock_timestamp();
          msg = 'Remove nodes between edges';
          sql = 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
          PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
          delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
          IF true THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'Removing of Overlaps failed: %', SQLERRM;
        END;

      EXCEPTION WHEN OTHERS THEN
        if i = 3 THEN
          -- Error in 3. try of adding the polygon to topology
          RAISE WARNING '%. try of loading polygon_id: % with tolerance % failed: %', i, polygon_id, topo_tolerance * factor, SQLERRM;
          f = f + 1;
          msg = 'Write Error Message.';
          sql = '
            UPDATE ' || topo_name || '.topo_geom
            SET err_msg = ''' || SQLERRM || ' with tolerance' || topo_tolerance * factor || '''
            WHERE polygon_id = ' || polygon_id || '
          ';
          PERFORM gdi_logsql('addToTopo', msg, sql); EXECUTE sql;
        ELSE
          -- give him a next try
          i = i + 1;
          EXECUTE FORMAT('
            SELECT gdi_addToTopo(
              %1$L, %2$L, %3$s, %4$s, %5$s, %6$s, %7$s, %8$L
            )',
            topo_name, geom_column, topo_tolerance, area_tolerance, polygon_id, f, i, debug
          )
          INTO f;
        END IF;
      END;
    END IF;
    RETURN f;
  END;
$BODY$
LANGUAGE plpgsql VOLATILE COST 100;

