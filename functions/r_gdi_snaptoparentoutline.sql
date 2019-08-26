DROP FUNCTION IF EXISTS public.gdi_snaptoparentoutline(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying);

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
RETURNS boolean AS
$BODY$
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
		split_table character varying = parent_table || '_' || child_table || '_gap_splits';
		parent_poly character varying = parent_geom || '_poly';
		parent_poly_n character varying = parent_poly || '_n';
		parent_line character varying = parent_geom || '_line';
		child_agg_line character varying = child_geom || '_child_agg_line';
		child_cut character varying = child_geom || '_cut';
		child_korr character varying = child_geom || '_korr';
		function_name character varying;
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

		-- Prüfen ob es die Funktionen gdi_extendline, gdi_split_multi and gdi_intersections gibt
		function_name = 'gdi_extendline';
		sql = format('
			SELECT
				1
			FROM
				information_schema.routines
			WHERE
				routine_schema = ''public'' AND
				routine_type = ''FUNCTION'' AND
				routine_name = %1$L
		', function_name);
		IF debug THEN RAISE NOTICE 'Abfrage ob Funktion existiert: %', sql; END IF;
		EXECUTE sql INTO result;
		IF result IS NULL THEN
			RAISE EXCEPTION 'Die Funktion % existiert nicht!', function_name;
		END IF;

		function_name = 'gdi_split_multi';
		sql = format('
			SELECT
				1
			FROM
				information_schema.routines
			WHERE
				routine_schema = ''public'' AND
				routine_type = ''FUNCTION'' AND
				routine_name = %1$L
		', function_name);
		IF debug THEN RAISE NOTICE 'Abfrage ob Funktion existiert: %', sql; END IF;
		EXECUTE sql INTO result;
		IF result IS NULL THEN
			RAISE EXCEPTION 'Die Funktion % existiert nicht!', function_name;
		END IF;

		function_name = 'gdi_intersections';
		sql = format('
			SELECT
				1
			FROM
				information_schema.routines
			WHERE
				routine_schema = ''public'' AND
				routine_type = ''FUNCTION'' AND
				routine_name = %1$L
		', function_name);
		IF debug THEN RAISE NOTICE 'Abfrage ob Funktion existiert: %', sql; END IF;
		EXECUTE sql INTO result;
		IF result IS NULL THEN
			RAISE EXCEPTION 'Die Funktion % existiert nicht!', function_name;
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
					 ST_Transform(								(ST_Dump(%5$I)).geom , %9$s)::geometry(''POLYGON'', %9$s) AS %6$I,
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
					(ST_Dump(diff)).geom::geometry(''Polygon'', %11$s) geom,
					1 AS num_neighbors
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
				COMMENT ON TABLE %1$I.%10$I IS ''Die Tabelle beinhaltet die Lücken zwischen den inneren Flächen und den außenlinien der übergeordneten Flächen am Rand, aufgeteilt in Einzelpolygone und durchnummeriert pro parent_poly_n mit gap_poly_n'';
		 ', parent_schema, parent_table_poly, parent_pk, parent_poly, parent_poly_n, child_schema, child_table, child_fk, child_cut, gaps_table, child_srid, gap_poly_n
		);
		-- 1 parent_schema, 2 parent_table_poly, 3 parent_pk, 4 parent_poly, 5 parent_poly_n, 6 child_schema, 7 child_table, 8 child_fk, 9 child_cut, 10 gaps_table, 11 child_srid, 12 gap_poly_n 
		RAISE NOTICE 'SQL zum Anlegen einer Tabelle, die die Lücken zwischen Parent und Childs enthält: %', sql;
		EXECUTE sql;

		-- Ordne den Lücken die Anzahl der inneren Flächen zu, die Nachbarn sind.
		sql = Format('
				UPDATE
					%1$I.%10$I AS g
				SET
					num_neighbors = n.num_neighbors
				FROM
					(
						SELECT
							g.%3$I,
							g.%4$I,
							g.%11$I,
							c.%7$I,
							count(*) OVER (PARTITION BY g.%3$I, g.%4$I, g.%11$I) AS num_neighbors
						FROM
							%1$I.%10$I AS g JOIN
							%5$I.%6$I AS c ON (g.%3$I = c.%8$I AND ST_Touches(g.geom, c.%9$I)) JOIN
							%1$I.%2$I AS p ON (g.%3$I = p.%3$I AND g.%4$I = p.%4$I)
						ORDER BY
							g.%3$I,
							g.%4$I,
							g.%11$I,
							c.%7$I
					) n
				WHERE
					g.%3$I = n.%3$I AND
					g.%4$I = n.%4$I AND
					g.%11$I = n.%11$I
			', parent_schema, parent_table_poly, parent_pk, parent_poly_n, child_schema, child_table, child_pk, child_fk, child_cut, gaps_table, gap_poly_n
		);
		-- 1 parent_schema, 2 parent_table, 3 parent_pk, 4 parent_poly_n, 5 child_schema, 6 child_table, 7 child_pk, 8 child_fk, 9 child_cut, 10 gaps_table, 11 gap_poly_n								 
		RAISE NOTICE 'SQL zur Berechnung der an Lücken angrenzenden inneren Flächen pro Lückke: %', sql;
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
									%1$I.%6$I AS c ON (g.%3$I = c.%7$I AND ST_Touches(g.geom, c.%8$I))
							) foo
						WHERE
							num = 1
						GROUP BY
							%3$I,
							%10$I
					) AS gaps
				WHERE
					c.%7$I = gaps.%3$I AND
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
*/
		sql = Format('
			DROP TABLE IF EXISTS %1$I.%11$I;
			CREATE TABLE %1$I.%11$I AS
			SELECT DISTINCT
				%3$I,
				%4$I,
				%10$I,
				(ST_Dump(gdi_intersections(%8$I, geom_cut_arr, geom))).geom split_point
			FROM
				(
					SELECT
						g.%3$I,
						g.%4$I,
						g.%10$I,
						c.%8$I,
						array_agg(c.%8$I) OVER (PARTITION BY g.%3$I, g.%4$I, g.%10$I) AS geom_cut_arr,
						g.geom
					FROM
						%1$I.%9$I AS g JOIN
						%5$I.%6$I AS c ON (g.%3$I = c.%7$I AND ST_Touches(g.geom, c.%8$I)) JOIN
						%1$I.%2$I AS p ON (g.%3$I = p.%3$I AND g.%4$I = p.%4$I)
					WHERE
						g.num_neighbors > 1
				) foo
			GROUP BY %3$I, %4$I, %10$I, geom
			', parent_schema, parent_table_poly, parent_pk, parent_poly_n, child_schema, child_table, child_fk, child_cut, gaps_table, gap_poly_n, split_table
		);
		-- 1 parent_schema, 2 parent_table, 3 parent_pk, 4 parent_poly_n, 5 child_schema, 6 child_table, 7 child_fk, 8 child_cut, 9 gaps_table, 10 gap_poly_n, 11 split_table
		RAISE NOTICE 'SQL zur Berechnung der Punkte, von denen die Schnitte der Lücken ausgeführt werden: %', sql;
		EXECUTE sql;

		sql = Format('
				ALTER TABLE %1$I.%5$I ADD COLUMN perpendicular_point GEOMETRY(''POINT'', %6$s);
				ALTER TABLE %1$I.%5$I ADD COLUMN split_line GEOMETRY(''LINESTRING'', %6$s);
				UPDATE
					%1$I.%5$I AS s
				SET
					perpendicular_point = ST_LineInterpolatePoint(p.%7$I, ST_LineLocatePoint(p.%7$I, s.split_point)),
					split_line = gdi_extendline(
						ST_MakeLine(
							s.split_point,
							ST_LineInterpolatePoint(p.%7$I, ST_LineLocatePoint(p.%7$I, split_point))
						),
						1, 0.1, 1, 0
					)
				FROM
					%1$I.%2$I AS p
				WHERE
					p.%3$I = s.%3$I AND
					p.%4$I = s.%4$I
			', parent_schema, parent_table_poly, parent_pk, parent_poly_n, split_table, child_srid, parent_line
		);
		-- 1 parent_schema, 2 parent_table_poly, 3 parent_pk, 4 parent_poly_n, 5 split_table, 6 child_srid, 7 parent_line 
		RAISE NOTICE 'SQL zur Berechnung der Lotfußpunkte und der Schnittlinie zum Auftrennen der Lücken, die mehr als eine angrenzende Flächen haben: %', sql;
		EXECUTE sql;

		-- Verschneide Gaps mit Split lines und ordne den child zu
		sql = Format('
			UPDATE
				%9$I.%10$I c
			SET
				%8$I = ST_Multi(ST_Union(c.%8$I, agg_gaps.geom))
			FROM
				(
					SELECT
						c.%7$I,
						c.%8$I,
						ST_Union(gs.geom) geom
					FROM
						(
							SELECT
								g.%4$I, g.%5$I, g.%6$I,
								(ST_Dump(public.gdi_split_multi(
									g.geom,
									ST_Collect(s.split_line)
								))).geom AS geom
							FROM
								%1$I.%2$I s JOIN
								%1$I.%3$I g ON s.%4$I = g.%4$I AND s.%5$I = g.%5$I AND s.%6$I = g.%6$I
							GROUP BY
								g.%4$I, g.%5$I, g.%6$I, g.geom
							ORDER BY
								g.%4$I, g.%5$I, g.%6$I, g.geom
						) gs JOIN
						%9$I.%10$I c ON gs.%4$I = c.%11$I AND ST_Relate(c.%8$I, gs.geom, ''****1****'')
					GROUP BY
						c.%7$I, c.%8$I
				) agg_gaps
			WHERE
				agg_gaps.%7$I = c.%7$I
				', parent_schema, split_table, gaps_table, parent_pk, parent_poly_n, gap_poly_n, child_pk, child_korr, child_schema, child_table, child_fk
			);
			-- 1 parent_schema, 2 split_table, 3 gaps_table, 4 parent_pk, 5 parent_poly_n, 6 gap_poly_n, 7 child_pk, 8 child_korr, 9 child_schema, 10 child_table, 11 child_fk
			RAISE NOTICE 'SQL zur Zerlegung der gaps mit mehreren Nachbaren und Zuordnung zu den Nachbarn: %', sql;
			EXECUTE sql;

		/* Beispielabfrage
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
		*/
		RETURN true;
	END;
$BODY$
LANGUAGE 'plpgsql' COST 100 VOLATILE;

COMMENT ON FUNCTION public.gdi_snaptoparentoutline(character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying)
	IS 'This function fits the geometry child_geom of polygons from child_table to its semantical parents in parent_table related over parent_pk and child_fk. The corrected geometry will be saved in column child_korr a combination of the given name in child_geom + korr. This function requires the functions gdi_extendline, gdi_split_multi and gdi_intersections.';

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
*/