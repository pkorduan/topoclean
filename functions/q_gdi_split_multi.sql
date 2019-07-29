DROP FUNCTION IF EXISTS public.gdi_split_multi(geometry, geometry);
CREATE OR REPLACE FUNCTION public.gdi_split_multi(poly geometry, lines geometry)
RETURNS geometry
AS $BODY$
	DECLARE
		part geometry;
		line geometry;
		parts geometry = ST_Collect(poly);
		new_parts geometry;
  BEGIN
		FOR line IN SELECT (ST_Dump(ST_CollectionExtract(lines, 2))).geom LOOP
			--RAISE NOTICE 'Loop with line: % over parts: %', st_astext(line), ST_AsText(parts);
			FOR part IN SELECT ST_CollectionExtract(parts, 3) LOOP
				IF ST_Intersects(part, line) AND NOT ST_Touches(part, line) THEN
					RAISE NOTICE 'Split Polygon: % with Line: %', ST_AsText(part), ST_AsText(line); 
					new_parts = ST_Split(part, line);
					RAISE NOTICE 'Result: %', ST_AsText(new_parts);
				END IF;
			END LOOP;
			parts = new_parts;
		END LOOP;
		/* Example
		SELECT gdi_split_multi(
			st_geomfromtext('Polygon((1 0, 3 0, 3 2, 1 2, 1 0))', 0),
			ST_Collect(
				st_makeline(
						st_makepoint(0, 1),
						st_makepoint(4, 1)
				),
				st_makeline(
					st_makepoint(2, 0),
					st_makepoint(2, 4)
				)
			)
		)
		*/
RETURN parts;
	END;
$BODY$
LANGUAGE 'plpgsql' COST 100 VOLATILE;
COMMENT ON FUNCTION public.gdi_split_multi(geometry, geometry) IS 'Split Polygon or MultiPolygon poly by multiple lines (MultiLineString or GeometryCollection) and returning the resulting parts as Polygons in an GeometryCollection.';