-- Function: public.gdi_noseremovebuffer(geometry, double precision, character varying)

-- DROP FUNCTION public.gdi_noseremovebuffer(geometry, double precision, character varying);

CREATE OR REPLACE FUNCTION public.gdi_noseremovebuffer(
    geometry,
    buffer double precision,
    style character varying)
  RETURNS geometry AS
$BODY$
  SELECT
    ST_Buffer(
      ST_Buffer(
        ST_Buffer(
          ST_Buffer(
            $1,
            $2
          ),
          -1 * $2,
          $3
        ),
        -1 * $2,
        $3
      ),
      $2,
      $3
    )
$BODY$
  LANGUAGE sql IMMUTABLE
  COST 100;
