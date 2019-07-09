-- FUNCTION: public.gdi_snaptoparentoutline(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying)

-- DROP FUNCTION public.gdi_snaptoparentoutline(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying);

CREATE OR REPLACE FUNCTION public.gdi_snaptoparentoutline(
	child_schema character varying,
	child_table character varying,
	child_pk character varying,
	child_fk character varying,
	child_geom character varying,
	parent_schema character varying,
	parent_table character varying,
	parent_fk character varying,
	parent_geom character varying)
RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE 
AS $BODY$
  DECLARE
    sql text;
    debug BOOLEAN = FALSE;
    parent_srid INTEGER;
    child_srid INTEGER;
    result RECORD;
    parent_table_poly character varying = parent_table || '_poly';
    gaps_table character varying = parent_table || '_' || child_table || '_gaps';
    overlaps_table character varying = parent_table || '_' || child_table || '_overlaps';
    parent_poly character varying = parent_geom || '_poly';
    parent_poly_n character varying = parent_poly || '_n';
    parent_line character varying = parent_geom || '_line';
    child_agg_line character varying = child_geom || '_child_agg_line';
    child_cut character varying = child_geom || '_cut';
    child_korr character varying = child_geom || '_korr';
  BEGIN
    -- Prüfen ob es parent_schema, parent_table, parent_fk und parent_geom gibt
    sql = format('
      SELECT 1 FROM information_schema.schemata
      WHERE
        schema_name = %1$L
    ', parent_schema);
    IF debug THEN RAISE NOTICE 'Abfrage ob schema existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Das Schema % existiert nicht!', parent_schema;
    END IF;

    sql = format('
      SELECT 1 FROM information_schema.tables
      WHERE
        table_schema = %1$L AND
        table_name = %2$L
    ', parent_schema, parent_table);
    IF debug THEN RAISE NOTICE 'Abfrage ob table existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Tabelle %.% existiert nicht!', parent_schema, parent_table;
    END IF;

    sql = format('
      SELECT 1 FROM information_schema.columns
      WHERE
        table_schema = %1$L AND
        table_name = %2$L AND
        column_name = %3$L
    ', parent_schema, parent_table, parent_fk);
    IF debug THEN RAISE NOTICE 'Abfrage ob Attributspalte existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Attributspalte % existiert nicht in Tabelle %.%!', parent_fk, parent_schema, parent_table;
    END IF;

    sql = format('
      SELECT 1 FROM information_schema.columns
      WHERE
        table_schema = %1$L AND
        table_name = %2$L AND
        column_name = %3$L
    ', parent_schema, parent_table, parent_geom);
    IF debug THEN RAISE NOTICE 'Abfrage ob Geometriespalte existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Geometriespalte % existiert nicht in Tabelle %.%!', parent_geom, parent_schema, parent_table;
    END IF;

    -- Prüfen ob es child_schema, child_table, child_fk child_pk und child_geom gibt
    sql = format('
      SELECT 1 FROM information_schema.schemata
      WHERE
        schema_name = %1$L
    ', child_schema);
    IF debug THEN RAISE NOTICE 'Abfrage ob schema existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Das Schema % existiert nicht!', child_schema;
    END IF;

    sql = format('
      SELECT 1 FROM information_schema.tables
      WHERE
        table_schema = %1$L AND
        table_name = %2$L
    ', child_schema, child_table);
    IF debug THEN RAISE NOTICE 'Abfrage ob table existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Tabelle %.% existiert nicht!', child_schema, child_table;
    END IF;

    sql = format('
      SELECT 1 FROM information_schema.columns
      WHERE
        table_schema = %1$L AND
        table_name = %2$L AND
        column_name = %3$L
    ', child_schema, child_table, child_fk);
    IF debug THEN RAISE NOTICE 'Abfrage ob Attributspalte existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Attributspalte % existiert nicht in Tabelle %.%!', child_fk, child_schema, child_table;
    END IF;

    sql = format('
      SELECT 1 FROM information_schema.columns
      WHERE
        table_schema = %1$L AND
        table_name = %2$L AND
        column_name = %3$L
    ', child_schema, child_table, child_pk);
    IF debug THEN RAISE NOTICE 'Abfrage ob Attributspalte existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Attributspalte % existiert nicht in Tabelle %.%!', child_pk, child_schema, child_table;
    END IF;

    sql = format('
      SELECT 1 FROM information_schema.columns
      WHERE
        table_schema = %1$L AND
        table_name = %2$L AND
        column_name = %3$L
    ', child_schema, child_table, child_geom);
    IF debug THEN RAISE NOTICE 'Abfrage ob Geometriespalte existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Geometriespalte % existiert nicht in Tabelle %.%!', child_geom, child_schema, child_table;
    END IF;

    -- Prüfen ob es schon child_korr gibt.
    sql = format('
      SELECT 1 FROM information_schema.columns
      WHERE
        table_schema = %1$L AND
        table_name = %2$L AND
        column_name = %3$L
    ', child_schema, child_table, child_korr);
    IF debug THEN RAISE NOTICE 'Abfrage ob Geometriespalte für korrigierte Geometrien existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NOT NULL THEN
      RAISE EXCEPTION 'Die Geometriespalte existiert schon in Tabelle %.%!', child_korr, child_schema, child_table;
    END IF;

    -- srid der parent geom abfragen
    sql = Format('
        SELECT
          ST_Srid(%3$s) AS parent_srid
        FROM
          %1$s.%2$s
        LIMIT 1
      ',
      parent_schema, parent_table, parent_geom
    );
    EXECUTE sql INTO parent_srid;

    -- srid der child geom abfragen
    sql = Format('
        SELECT
          ST_Srid(%3$s) AS child_srid
        FROM
          %1$s.%2$s
        LIMIT 1
      ',
      child_schema, child_table, child_geom
    );
    EXECUTE sql INTO child_srid;

    -- Anlegen einer Tabelle für die Polygone der Multipolygone der Parent-Tabelle
    sql = Format('
        DROP TABLE IF EXISTS %1$I.%3$I;
        CREATE TABLE %1$I.%3$I AS
        SELECT
            %4$I,
           ST_Transform(                (ST_Dump(%5$I)).geom , %9$s)::geometry(''POLYGON'', %9$s) AS %6$I,
           ST_Transform(ST_ExteriorRing((ST_Dump(%5$I)).geom), %9$s)::geometry(''LINESTRING'', %9$s) AS %8$I,
           (ST_Dump(%5$I)).path[1] AS %7$I
        FROM
           %1$I.%2$I;
        CREATE INDEX %3$s_%6$s_gist ON %1$I.%3$I USING GIST (%6$I);
        CREATE INDEX %3$s_%8$s_gist ON %1$I.%3$I USING GIST (%8$I);
     ', parent_schema, parent_table, parent_table_poly, parent_fk, parent_geom, parent_poly, parent_poly_n, parent_line, child_srid
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_table_poly, 4 parent_fk, 5 parent_geom, 6 parent_poly, 7 parent_poly_n, 8 parent_line, 9 child_srid
    RAISE NOTICE 'SQL zum Anlegen einer Tabelle, die die Einzelpolygone und Outlines der festen Flächen beinhalen soll: %', sql;
    EXECUTE sql;

    -- Anlegen der Spalten für die verschnittene und korrigierte Geometrie der variablen Flächen in der Child Tabelle
    sql = Format('
        ALTER TABLE %1$I.%2$I DROP COLUMN IF EXISTS %3$I;
        ALTER TABLE %1$I.%2$I ADD COLUMN %3$I geometry(''MULTIPOLYGON'', %5$s);
        ALTER TABLE %1$I.%2$I DROP COLUMN IF EXISTS %4$I;
        ALTER TABLE %1$I.%2$I ADD COLUMN %4$I geometry(''MULTIPOLYGON'', %5$s);
      ', child_schema, child_table, child_cut, child_korr, child_srid
    );
    -- 1 child_schema, 2 child_table, 3 child_cut, 4 child_korr, 5 child_srid
    EXECUTE sql;

    -- Abschneiden der überstehenden Flächen
    sql = Format('
        UPDATE
          %5$I.%6$I AS c
        SET
          %9$I = ST_Multi(CASE WHEN ST_CoveredBy(c.%8$I, p.%4$I) THEN c.%8$I ELSE ST_Intersection(c.%8$I, p.%4$I) END),
          %10$I = c.%8$I
        FROM
          %1$I.%2$I AS p
        WHERE
          p.%3$I = c.%7$I
      ',
      parent_schema, parent_table, parent_fk, parent_geom,
      child_schema, child_table, child_fk, child_geom, child_cut, child_korr
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_fk, 4 parent_geom, 5 child_schema, 6 child_table, 7 child_fk, 8 child_geom, 9 child_cut, 10 child_korr
    EXECUTE sql;

    -- Anlegen einer Tabelle für die Stücke der childs, die über die parents hinausragen
    sql = Format('
        DROP TABLE IF EXISTS %1$I.%9$I;
        CREATE TABLE %1$I.%9$I AS
        SELECT
           p.%3$I AS parent_%3$s,
           c.%7$I AS child_%7$s,
           (ST_Dump(ST_Difference(c.%8$I, p.%4$I))).geom::geometry(''Polygon'', %10$s) AS geom
        FROM
           %1$I.%2$I p JOIN
           %5$I.%6$I c ON p.%3$I = c.%7$I;
        CREATE INDEX %9$s_geom_gist ON %1$I.%9$I USING GIST (geom);
     ', parent_schema, parent_table, parent_fk, parent_geom, child_schema, child_table, child_fk, child_geom, overlaps_table, child_srid
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_fk, 4 parent_geom, 5 child_schema, 6 child_table, 7 child_fk, 8 child_geom, 9 overlaps_table, 10 child_srid
    RAISE NOTICE 'SQL zum Anlegen einer Tabelle, die die Lücken zwischen Parent und Childs enthält: %', sql;
    EXECUTE sql;

    -- Anlegen einer Tabelle für die Lücken zwischen childs und parents
    sql = Format('
        DROP TABLE IF EXISTS %1$I.%9$I;
        CREATE TABLE %1$I.%9$I AS
        SELECT
           p.%3$I,
           generate_series(1, ST_NumGeometries(ST_Difference(p.%4$I, ST_Collect(c.%8$I)))) AS n,
           (ST_Dump(ST_Difference(p.%4$I, ST_Collect(c.%8$I)))).geom::geometry(''Polygon'', %10$s) AS geom
        FROM
           %1$I.%2$I p JOIN
           %5$I.%6$I c ON p.%3$I = c.%7$I
        GROUP BY p.%3$I;
        CREATE INDEX %9$s_geom_gist ON %1$I.%9$I USING GIST (geom);
     ', parent_schema, parent_table, parent_fk, parent_geom, child_schema, child_table, child_fk, child_cut, gaps_table, child_srid
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_fk, 4 parent_geom, 5 child_schema, 6 child_table, 7 child_fk, 8 child_cut, 9 gaps_table, 10 child_srid 
    RAISE NOTICE 'SQL zum Anlegen einer Tabelle, die die Lücken zwischen Parent und Childs enthält: %', sql;
    EXECUTE sql;

    -- Verschmelze die beschnittenen Child-Flächen mit den Lücken, die nur an einem Child anliegen und update die Spalte der korrigierten Geometrien
    sql = Format('
        UPDATE
          %4$I.%5$I c
        SET
          %8$I = sub.%8$I
        FROM
          (
            SELECT
              c.%9$I,
              ST_Multi(ST_Union(c.%7$I, ST_CollectionExtract(ST_Union(g.geom), 3))) AS %8$I
            FROM
              %1$I.%2$I AS g JOIN
              %4$I.%5$I AS c ON (g.%3$I = c.%6$I AND ST_Touches(g.geom, c.%7$I))
            GROUP BY
              c.%9$I
            HAVING count(c.%9$I) = 1
          ) sub
        WHERE
          c.%9$I = sub.%9$I
      ', parent_schema, gaps_table, parent_fk, child_schema, child_table, child_fk, child_cut, child_korr, child_pk
    );
    RAISE NOTICE 'SQL zur Berechnung der korrigierten Child Geometrie: %', sql;
    -- 1 parent_schema, 2 gaps_table, 3 parent_fk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_cut, 8 child_korr, 9 child_pk
    EXECUTE sql;

    /*
    -- Fälle die Lotsenkrechten der outlines von Lücken, die an mehr als einer Child-Fläche grenzen auf die parent geom
    -- ToDo: Hier nur die bearbeiten, die an mehr als einer Child-Fläche anliegen
    sql = Format('
        DROP TABLE IF EXISTS anfangspunkte;
        CREATE TABLE anfangspunkte AS
        SELECT
          ST_StartPoint(c.outline)::geometry(''Point'', %3$s) as geom
        FROM
          %1$s.%2$s AS c
        WHERE
          c.outline IS NOT NULL;
        DROP TABLE IF EXISTS endpunkte;
        CREATE TABLE endpunkte AS
        SELECT
          ST_EndPoint(c.outline)::geometry(''Point'', %3$s) as geom
        FROM
          %1$s.%2$s AS c
        WHERE
          c.outline IS NOT NULL;
      ', child_schema, child_table, child_srid
    );
    RAISE NOTICE 'SQL zum Berechnen der Lotfußpunkte an den Enden der variablen Teilflächengrenzen: %', sql;
    EXECUTE sql;

    -- Bilde die Geometrie der geteilten Lückenflächen und verschmelze sie mit den Child-Flächen

*/
    RETURN true;
  END;
$BODY$;

/*
-- Beispielabfrage

SELECT gdi_SnapToParentOutline(
  'public',
  'ortsteile_hro',
	'gtl_schl',
  'gvb_schl',
  'geom',
  'public',
  'gemeindeverbaende_mv',
  'gvb_schl',
  'geom'
);

    -- Codesnipsel

    -- Anlegen einer Geometriespalte für die Linien der aggregierten beschnittenen Flächen. (child_agg_line)
    sql = Format('
        ALTER TABLE %1$I.%2$I DROP COLUMN IF EXISTS %3$I;
        ALTER TABLE %1$I.%2$I ADD COLUMN %3$I geometry(''MULTILINESTRING'', %4$s)
      ',
      parent_schema, parent_table_poly, child_agg_line, child_srid
    );
    EXECUTE sql;

    -- Bestimmung der Linestrings der beschnittenen und aggregierten Child-Flächen, child_agg_line
    sql = FORMAT('
        UPDATE
          %1$s.%2$s AS parent
        SET
          %8$I = child.agg_line
        FROM
          (
            SELECT
              p.%6$s,
              ST_Multi(
                ST_ExteriorRing(
                  ST_Union(
                    c.%7$s
                  )
                )
              ) AS agg_line
            FROM
              %1$s.%2$s AS p JOIN
              %4$s.%5$s AS c ON (p.%3$s = c.%6$s)
            GROUP BY
              p.%6$s,c.%6$s
          ) AS child
        WHERE
          parent.%3$s = child.%6$s
      ', parent_schema, parent_table_poly, parent_fk, child_schema, child_table, child_fk, child_cut, child_agg_line
    );
    -- parent_schema, 2 parent_table_poly, 3 parent_fk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_cut, 8 child_agg_line
    EXECUTE sql;

    -- Lege neue Spalte in der Child-Tabelle an für die äußeren Linien, die auf dem Aggregat liegen
    sql = Format('
        ALTER TABLE %1$s.%2$s DROP COLUMN IF EXISTS outline;
        ALTER TABLE %1$s.%2$s ADD COLUMN outline geometry(''LINESTRING'', %3$s)
      ',
      child_schema, child_table, child_srid
    );
    EXECUTE sql;

    -- Bestimmung der äußeren Linien der Child Flächen durch Verschneidung der Child-Flächen mit den Überlappuntsflächen
    sql = FORMAT('
        UPDATE
          %4$s.%5$s AS c
        SET
          outline = ST_CollectionExtract(ST_Intersection(o.geom, c.%7$I), 2)
        FROM
          %1$I.%2$I AS o
        WHERE
          o.parent_%3$s = c.%6$I AND
          ST_Touches(o.geom, c.%7$I)                 
      ', parent_schema, overlaps_table, parent_fk, child_schema, child_table, child_fk, child_cut
    );
    -- 1 parent_schema, 2 overlaps_table, 3 parent_fk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_cut
    RAISE NOTICE 'sql %', sql;
    EXECUTE sql;    

    -- Bestimmung der Teile der äußeren Linie die durch die child Flächen gebildet werden
    sql = FORMAT('
        UPDATE
          %4$s.%5$s AS c
        SET
          outline = ST_Multi(ST_LineMerge(ST_Intersection(c.%7$s, p.%8$I)))
        FROM
          %1$s.%2$s AS p
        WHERE
          ST_Intersects(c.%7$s, p.%8$I) AND
          p.%3$s = c.%6$s
      ', parent_schema, parent_table_poly, parent_fk, child_schema, child_table, child_fk, child_cut, child_agg_line
    );
    -- 1  parent_schema, 2 parent_table, 3 parent_fk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_geom, 8 child_agg_line
    RAISE NOTICE 'sql %', sql;
    EXECUTE sql;
*/

