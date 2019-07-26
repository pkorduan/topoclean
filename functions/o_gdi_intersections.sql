DROP AGGREGATE IF EXISTS gdi_intersections(geometry, geometry[], geometry);
DROP FUNCTION IF EXISTS public.gdi_intersections(geometry[], geometry, geometry[], geometry);

CREATE OR REPLACE FUNCTION public.gdi_intersections(points geometry[], neighbor_i geometry, neighbors geometry[], geom geometry)
RETURNS geometry[]
AS $BODY$
	DECLARE
		neighbor geometry;
  BEGIN
		FOREACH neighbor IN ARRAY neighbors LOOP
			IF NOT ST_Equals(neighbor, neighbor_i) AND neighbor && neighbor_i AND ST_Intersects(neighbor, neighbor_i) THEN
				points = array_append(points, ST_Intersection(ST_Intersection(neighbor, neighbor_i), geom));
			END IF;
		END LOOP;
		RETURN points;
	END;
$BODY$
LANGUAGE 'plpgsql' COST 100 VOLATILE;

CREATE AGGREGATE public.gdi_intersections(geometry, geometry[], geometry) (
	sfunc = gdi_intersections,
	stype = geometry[],
	finalfunc = ST_Collect,
	initCond = '{}'
);

/*
DROP AGGREGATE IF EXISTS gdi_intersections(geometry);
DROP FUNCTION IF EXISTS public.gdi_intersections(geometry[]);

CREATE OR REPLACE FUNCTION public.gdi_intersections(geom_array geometry[])
RETURNS geometry
AS $BODY$
	DECLARE
		geom geometry;
		geom_intersection geometry;
  BEGIN
		FOREACH geom IN ARRAY geom_array LOOP
			IF geom_intersection IS NULL THEN
				geom_intersection = geom;
			ELSE
		  	geom_intersection = ST_Intersection(geom_intersection, geom);
			END IF;
		END LOOP;
		RETURN geom_intersection;	
	END;
$BODY$
LANGUAGE 'plpgsql' COST 100 VOLATILE;


DROP FUNCTION IF EXISTS public.gdi_intersections(geometry[], geometry);
CREATE OR REPLACE FUNCTION public.gdi_intersections(neighbors geometry[], geom geometry)
RETURNS geometry
AS $BODY$
	DECLARE
		geom_a geometry;
		geom_b geometry;
		geom_i geometry[];
  BEGIN
		FOREACH geom_a IN ARRAY neighbors LOOP
			FOREACH geom_b IN ARRAY neighbors LOOP
				IF NOT ST_Equals(geom_a, geom_b) AND geom_a && geom_b AND ST_Intersects(geom_a, geom_b) THEN
					geom_i = array_append(geom_i, ST_Intersection(ST_Intersection(geom_a, geom_b), geom));
				END IF;
			END LOOP;
		END LOOP;
		RETURN geom_i;
	END;
$BODY$
LANGUAGE 'plpgsql' COST 100 VOLATILE;

DROP FUNCTION IF EXISTS public.gdi_array_append_first(geometry[], geometry, geometry);
CREATE OR REPLACE FUNCTION public.gdi_array_append_first(arr geometry[], elm geometry, ign geometry)
RETURNS geometry[]
AS $BODY$
	DECLARE
  BEGIN
		RETURN array_append(arr, elm);	
	END;
$BODY$
LANGUAGE 'plpgsql' COST 100 VOLATILE;
COMMENT ON FUNCTION public.gdi_array_append_first(geometry[], geometry, geometry) IS 'Function append argument elm to the end of Array arr and ignore ign.';

DROP AGGREGATE IF EXISTS gdi_intersections(geometry);
CREATE AGGREGATE public.gdi_intersections(geometry, geometry) (
	sfunc = gdi_array_append_first,
	stype = geometry[],
	finalfunc = gdi_intersections,
	initCond = '{}'
);
*/

/*
Dieses Beispiel zeigt wie Aggregate mit mehr als einem Parameter Funktionieren.
DROP FUNCTION  IF EXISTS public.atest_sfunc(text[], text, text[], text)
CREATE OR REPLACE FUNCTION public.atest_sfunc(state text[], a text, b text[], c text)
RETURNS text[]
AS $BODY$
	DECLARE
	BEGIN
		RETURN array_append(state, a || ':' || array_length(b, 1)::text || '-' || c);
	END;
$BODY$
LANGUAGE 'plpgsql' COST 100 VOLATILE;

DROP AGGREGATE  IF EXISTS public.atest(text, text[], text);
CREATE AGGREGATE public.atest(text, text[], text) (
	sfunc = atest_sfunc,
	stype = text[],
--	finalfunc = atest_ffunc,
	initCond = '{}'
);

SELECT
	public.atest(
	ctext,
	ARRAY['1', '2','3']::text[],
	'c'::text)
FROM
(VALUES ('1'), ('2'), ('3')) AS t(ctext)
*/