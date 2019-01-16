--DROP function gdi_cleanPolygon(geometry, integer, double precision, double precision)
--DROP function gdi_cleanPolygon(geometry, integer, double precision, double precision)
CREATE OR REPLACE FUNCTION public.gdi_cleanPolygon(
  geom geometry,
  epsg_code integer,
  distance_tolerance double precision,
  area_tolerance double precision
)
RETURNS SETOF record AS
$$
  SELECT
    ST_GeometryN(
      geom,
      generate_series(
        1,
        ST_NumGeometries(geom)
      )
    ) AS geom
  FROM
    (
      SELECT
        gdi_FilterRings(
          gdi_FingerCut(
            ST_CollectionExtract(
              ST_MakeValid(
                 ST_SimplifyPreserveTopology(
                  ST_Transform(
                    $1,
                    $2
                  ),
                  $3
                )
              ),
              3
            ),
            $3
          ),
          $4
        ) AS geom
    ) foo
$$
LANGUAGE sql STABLE;