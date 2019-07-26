DROP FUNCTION public.gdi_snaptoparentoutline(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying);

CREATE OR REPLACE FUNCTION public.gdi_snaptoparentoutline(
	child_schema character varying,
	child_table character varying,
	child_pk character varying,
	child_fk character varying,
	child_geom character varying,
	parent_schema character varying,
	parent_table character varying,
	parent_pk character varying,
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
		gap_poly_n character varying = 'gap_poly_n';
		overlaps_table character varying = parent_table || '_' || child_table || '_overlaps';
    parent_poly character varying = parent_geom || '_poly';
    parent_poly_n character varying = parent_poly || '_n';
    parent_line character varying = parent_geom || '_line';
		child_agg_line character varying = child_geom || '_child_agg_line';
    child_cut character varying = child_geom || '_cut';
    child_korr character varying = child_geom || '_korr';
  BEGIN
    -- Prüfen ob es parent_schema, parent_table, parent_pk und parent_geom gibt
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
    ', parent_schema, parent_table, parent_pk);
    IF debug THEN RAISE NOTICE 'Abfrage ob Attributspalte existiert: %', sql; END IF;
    EXECUTE sql INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Die Attributspalte % existiert nicht in Tabelle %.%!', parent_pk, parent_schema, parent_table;
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
		-- PK ist parent_pk und parent_poly_n aus path
    sql = Format('
        DROP TABLE IF EXISTS %1$I.%3$I;
        CREATE TABLE %1$I.%3$I AS
        SELECT
            %4$I,
           (ST_Dump(%5$I)).path[1] AS %7$I,
					 ST_Transform(                (ST_Dump(%5$I)).geom , %9$s)::geometry(''POLYGON'', %9$s) AS %6$I,
           ST_Transform(ST_ExteriorRing((ST_Dump(%5$I)).geom), %9$s)::geometry(''LINESTRING'', %9$s) AS %8$I
        FROM
           %1$I.%2$I;
				ALTER TABLE %1$I.%3$I ADD CONSTRAINT %3$s_pkey PRIMARY KEY (%4$I, %7$I);
				CREATE INDEX %3$s_%6$s_gist ON %1$I.%3$I USING GIST (%6$I);
        CREATE INDEX %3$s_%8$s_gist ON %1$I.%3$I USING GIST (%8$I);
     ', parent_schema, parent_table, parent_table_poly, parent_pk, parent_geom, parent_poly, parent_poly_n, parent_line, child_srid
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_table_poly, 4 parent_pk, 5 parent_geom, 6 parent_poly, 7 parent_poly_n, 8 parent_line, 9 child_srid
    RAISE NOTICE 'SQL zum Anlegen einer Tabelle, die die Einzelpolygone und Outlines der festen Flächen beinhalen soll: %', sql;
    EXECUTE sql;

		-- Zuordnung der festen Polygone zu den variablen-Flächen. Jedes child-Fläche gehört zu genau einem Polygon
		-- Das Polygon ist mit dem parent_pk und 

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
      parent_schema, parent_table, parent_pk, parent_geom,
      child_schema, child_table, child_fk, child_geom, child_cut, child_korr
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_pk, 4 parent_geom, 5 child_schema, 6 child_table, 7 child_fk, 8 child_geom, 9 child_cut, 10 child_korr
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
     ', parent_schema, parent_table, parent_pk, parent_geom, child_schema, child_table, child_fk, child_geom, overlaps_table, child_srid
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_pk, 4 parent_geom, 5 child_schema, 6 child_table, 7 child_fk, 8 child_geom, 9 overlaps_table, 10 child_srid
    RAISE NOTICE 'SQL zum Anlegen einer Tabelle, die die Lücken zwischen Parent und Childs enthält: %', sql;
    EXECUTE sql;

    -- Anlegen einer Tabelle für die Lücken zwischen childs und parent polygonen
		-- Der pkey besteht aus der parent_pk, parent_poly_n und gap_poly_n ... Nummer der Polygone der berechneten Lücke pro parent polygon
    sql = Format('
        DROP TABLE IF EXISTS %1$I.%10$I;
        CREATE TABLE %1$I.%10$I AS
			  SELECT
           %3$I,
					 %5$I,
					(ST_Dump(diff)).path[1] AS %12$I,
					(ST_Dump(diff)).geom::geometry(''Polygon'', %11$s) geom					 
				FROM
			    (
					  SELECT
            	p.%3$I,
					  	p.%5$I,
							ST_Difference(p.%4$I, ST_Collect(c.%9$I)) diff
        		FROM
          		%1$I.%2$I p JOIN
          		%6$I.%7$I c ON p.%3$I = c.%8$I
        		GROUP BY p.%3$I, p.%5$I
					) diff_tab;
        CREATE INDEX %10$s_geom_gist ON %1$I.%10$I USING GIST (geom);
     ', parent_schema, parent_table_poly, parent_pk, parent_poly, parent_poly_n, child_schema, child_table, child_fk, child_cut, gaps_table, child_srid, gap_poly_n
    );
    -- 1 parent_schema, 2 parent_table, 3 parent_pk, 4 parent_geom, 5 parent_poly_n, 6 child_schema, 7 child_table, 8 child_fk, 9 child_cut, 10 gaps_table, 11 child_srid, 12 gap_poly_n 
    RAISE NOTICE 'SQL zum Anlegen einer Tabelle, die die Lücken zwischen Parent und Childs enthält: %', sql;
    EXECUTE sql;

    -- Verschmelze die beschnittenen Child-Flächen mit den Lücken, die nur an einem Child anliegen und update die Spalte der korrigierten Geometrien
    sql = Format('
				UPDATE
					%5$I.%6$I c
				SET
					%9$I = ST_Multi(ST_Union(c.%8$I, gaps.geom))
				FROM
					(
						SELECT
							%3$I,
							%10$I,
							ST_CollectionExtract(ST_Union(foo.geom), 3) geom
						FROM
							(
								SELECT
									g.%3$I,
									g.%4$I,
									c.%10$I,
									count(*) OVER (PARTITION BY g.%3$I, g.%4$I, g.%11$I) AS num,
									g.geom
								FROM
									%1$I.%2$I AS g JOIN
									%1$I.%6$I AS c ON (g.%3$I = c.%3$I AND ST_Touches(g.geom, c.%8$I))
							) foo
						WHERE
							num = 1
						GROUP BY
							%3$I,
							%10$I
					) AS gaps
				WHERE
					c.%3$I = gaps.%3$I AND
					c.%10$I = gaps.%10$I
      ', parent_schema, gaps_table, parent_pk, parent_poly_n, child_schema, child_table, child_fk, child_cut, child_korr, child_pk, gap_poly_n
    );
    RAISE NOTICE 'SQL zur Berechnung der korrigierten Child Geometrie: %', sql;
    -- 1 parent_schema, 2 gaps_table, 3 parent_pk, 4 parent_poly_n, 5 child_schema, 6 child_table, 7 child_fk, 8 child_cut, 9 child_korr, 10 child_pk, 11 gap_poly_n
    EXECUTE sql;

    /*
    Die Aufteilung der Lücken, die an mehreren Child-Flächen angrenzen geht nicht über die outline Start und Endpoints, weil die outlines merkwürdigerweise manchmal MultiLineStrings sind, die sich nicht zu einer gerichteten Linie mit Anfang und Ende zusammenfügen lassen.
    Neuer Ansatz daher:
    - Verschneidung jweils aller angrenzender Nachbarn mit der Lücke. Übrig bleiben dürften die Punkte zwischen benachbarter Nachbarn auf der Linie an der Lücke.
    - Lotfusspunkte auf die Außenlinie des Polygons und Linien dahin bilden und mit der Lücke verschneiden. Die Teile dem Nachbarn zuordnen zu dem die längste Touch-linie liegt (eigentlich zu dem die einzige Intersects linie liegt, aber da bei Touch wohl wieder nicht nur der eine Nachbar gefunden wird nimm den mit der längsten Linie. Die Verschneidung mit den anderen Nachbarn dürften nur Punkte ergeben.)

SELECT
  gvb_schl,
	geom_poly_n,
	gap_poly_n,
  geom,
	gdi_intersections(geom_cut, geom_cut_arr, geom)
FROM
	(
		SELECT
			g.gvb_schl,
			g.geom_poly_n,
			g.gap_poly_n,
			c.gtl_schl,
			c.geom_cut,
--			(ST_Dump(ST_Intersection(g.geom, gdi_intersections(c.geom_cut) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n)))).geom AS geom_i,
			array_agg(c.geom_cut) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n) AS geom_cut_arr,
			g.geom,
		  count(*) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n) AS num--,
--			ST_MakeLine(
--				(ST_Dump(ST_Intersection(g.geom, gdi_intersections(c.geom_cut) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n)))).geom,
--				ST_LineInterpolatePoint(p.geom_line, ST_LineLocatePoint(p.geom_line, (ST_Dump(ST_Intersection(g.geom, gdi_intersections(c.geom_cut) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n)))).geom))
--			) cut_geom

		FROM
			public.gemeindeverbaende_mv_ortsteile_hro_gaps AS g JOIN
			public.ortsteile_hro AS c ON (g.gvb_schl = c.gvb_schl AND ST_Touches(g.geom, c.geom_cut)) JOIN
			public.gemeindeverbaende_mv_poly AS p ON (g.gvb_schl = p.gvb_schl AND g.geom_poly_n = p.geom_poly_n)
		ORDER BY
			g.gvb_schl,
			g.geom_poly_n,
			g.gap_poly_n,
			c.gtl_schl
) foo
WHERE
  array_length(geom_cut_arr, 1) > 1
GROUP BY gvb_schl, geom_poly_n, gap_poly_n, geom
	

		sql = Format('
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
      ', parent_schema, gaps_table, parent_pk, child_schema, child_table, child_fk, child_cut, child_korr, child_pk
    );
    RAISE NOTICE 'SQL zur Berechnung der korrigierten Child Geometrie: %', sql;
    -- 1 parent_schema, 2 gaps_table, 3 parent_pk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_cut, 8 child_korr, 9 child_pk
    EXECUTE sql;
	
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
/*
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
      ', parent_schema, parent_table_poly, parent_pk, child_schema, child_table, child_fk, child_cut, child_agg_line
    );
    -- parent_schema, 2 parent_table_poly, 3 parent_pk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_cut, 8 child_agg_line
    EXECUTE sql;

    -- Lege neue Spalte in der Child-Tabelle an für die äußeren Linien, die auf dem Aggregat liegen
    sql = Format('
        ALTER TABLE %1$s.%2$s DROP COLUMN IF EXISTS outline;
        ALTER TABLE %1$s.%2$s ADD COLUMN outline geometry(''LINESTRING'', %3$s)
      ',
      child_schema, child_table, child_srid
    );
    EXECUTE sql;

    -- Bestimmung der äußeren Linien der Child Flächen durch Verschneidung der Child-Flächen mit den Überlappungsflächen
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
      ', parent_schema, overlaps_table, parent_pk, child_schema, child_table, child_fk, child_cut
    );
    -- 1 parent_schema, 2 overlaps_table, 3 parent_pk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_cut
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
      ', parent_schema, parent_table_poly, parent_pk, child_schema, child_table, child_fk, child_cut, child_agg_line
    );
    -- 1  parent_schema, 2 parent_table, 3 parent_pk, 4 child_schema, 5 child_table, 6 child_fk, 7 child_geom, 8 child_agg_line
    RAISE NOTICE 'sql %', sql;
    EXECUTE sql;

BEGIN;

CREATE FUNCTION sum_product_fn(int,int,int) RETURNS int AS $$
    SELECT $1 + ($2 * $3);
$$ LANGUAGE SQL;           

CREATE AGGREGATE sum_product(int, int) (
    sfunc = sum_product_fn,
    stype = int, 
    initcond = 0
);

SELECT 
    sum(i) AS one,     
    sum_product(i, 2) AS double,
    sum_product(i,3) AS triple
FROM generate_series(1,3) i;

ROLLBACK; 


SELECT
	*
FROM
	(
		SELECT
			g.gvb_schl,
			g.geom_poly_n,
			g.gap_poly_n,
			c.gtl_schl,
			ST_GeometryType(ST_Intersection(g.geom, c.geom_cut)),
			count(*) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n) AS num
/*
					(ST_Dump(ST_Intersection(g.geom, gdi_intersections(c.geom_cut) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n)))).geom AS geom_i,
		ST_MakeLine(
				(ST_Dump(ST_Intersection(g.geom, gdi_intersections(c.geom_cut) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n)))).geom,
				ST_LineInterpolatePoint(p.geom_line, ST_LineLocatePoint(p.geom_line, (ST_Dump(ST_Intersection(g.geom, gdi_intersections(c.geom_cut) OVER (PARTITION BY g.gvb_schl, g.geom_poly_n, g.gap_poly_n)))).geom))
			) cut_geom*/
		FROM
			public.gemeindeverbaende_mv_ortsteile_hro_gaps AS g JOIN
			public.ortsteile_hro AS c ON (g.gvb_schl = c.gvb_schl AND ST_Touches(g.geom, c.geom_cut)) JOIN
			public.gemeindeverbaende_mv_poly AS p ON (g.gvb_schl = p.gvb_schl AND g.geom_poly_n = p.geom_poly_n)
		ORDER BY
			g.gvb_schl,
			g.geom_poly_n,
			g.gap_poly_n,
			c.gtl_schl
) foo
WHERE
  geom_poly_n = 1 AND
	gap_poly_n = 702 AND
  num > 1
	
	-- Liefert die Punkte an Schnittpunkten von Nachbarn und Gap, wenn die geoms der beteiligten Nachbarn in child_geoms[] stecken.
				SELECT DISTINCT
					ST_Intersection(ST_Intersection(a.geom, b.geom), gap_geom)
				FROM
					unnest(child_geoms) AS child_geoms(geom) AS a,
					unnest(child_geoms) AS child_geoms(geom) AS b
				WHERE
					a.geom != b.geom AND
					ST_Touches(a.geom, b.geom)

  -- Gapzuordnung in 2 läufen.
	-- 1. Schnittpunkte finden und gap zerteilen
	-- 2. Zuordnen der Teile zu den child-Flächen über touches oder intersection typ line

*/

