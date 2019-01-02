-- DROP FUNCTION public.gdi_fingercut(geometry, double precision);
CREATE OR REPLACE FUNCTION public.gdi_fingercut(
    poly geometry,
    distance_tolerance double precision)
  RETURNS geometry AS
$BODY$
  DECLARE
    newpoly geometry;
  BEGIN
    -- cut outer fingers
    poly = ST_Intersection(
      poly,
      ST_Buffer(
        ST_Buffer(
          poly,
          -1 * distance_tolerance,
          1
        ),
        1.5 * distance_tolerance,
        1
      )
    );
    -- invert Polygon
    poly = ST_Difference(
      ST_Expand(poly, 10 * distance_tolerance),
      poly
    );
    -- cut inner fingers
    poly = ST_Intersection(
      poly,
      ST_Buffer(
        ST_Buffer(
          poly,
          -1 * distance_tolerance,
          1
        ),
        1.5 * distance_tolerance,
        1
      )
    );
    -- reinvert polygon
    poly = ST_Difference(
      ST_Expand(poly, -5 * distance_tolerance),
      poly
    );

    RETURN poly;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_fingercut(geometry, double precision) IS 'Cut outer and inner finger of a multi or polygon with a given distance_tolerance.';

