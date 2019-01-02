-- DROP FUNCTION public.gdi_FilterRings(geometry, double precision);
CREATE OR REPLACE FUNCTION public.gdi_FilterRings(
  polygon geometry,
  area_tolerance double precision
)
RETURNS geometry AS
$BODY$
 SELECT ST_Collect( CASE WHEN d.inner_rings is NULL OR NOT st_within(st_collect(d.inner_rings), ST_MakePolygon(c.outer_ring)) THEN ST_MakePolygon(c.outer_ring) ELSE ST_MakePolygon(c.outer_ring, d.inner_rings) END) as final_geom		-- am 20.07.2016 angepasst
  FROM (/* Get outer ring of polygon */
        SELECT ST_ExteriorRing(b.the_geom) as outer_ring
          FROM (SELECT (ST_DumpRings((ST_Dump($1)).geom)).geom As the_geom, path(ST_DumpRings((ST_Dump($1)).geom)) as path) b
          WHERE b.path[1] = 0 /* ie the outer ring */
        ) c,
       (/* Get all inner rings > a particular area */
        SELECT ST_Accum(ST_ExteriorRing(b.the_geom)) as inner_rings
          FROM (SELECT (ST_DumpRings((ST_Dump($1)).geom)).geom As the_geom, path(ST_DumpRings((ST_Dump($1)).geom)) as path) b
          WHERE b.path[1] > 0 /* ie not the outer ring */
            AND ST_Area(b.the_geom) > $2
        ) d
 $BODY$
  LANGUAGE sql IMMUTABLE
  COST 100;
COMMENT ON FUNCTION public.gdi_FilterRings(geometry, DOUBLE PRECISION) IS 'Remove inner rings of polygon with area <= area_tolerance.';

