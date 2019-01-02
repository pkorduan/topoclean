-- DROP FUNCTION public.gdi_noseremove(character varying, integer, geometry, double precision, double precision, boolean);
CREATE OR REPLACE FUNCTION public.gdi_noseremove(
    topo_name character varying,
    polygon_id integer,
    geometry,
    angle double precision,
    tolerance double precision,
    debug boolean)
  RETURNS geometry AS
$BODY$ 
  SELECT ST_MakePolygon(
    (
      --outer ring of polygon
      SELECT ST_ExteriorRing(gdi_NoseRemoveCore($1, $2, geom, $4, $5, $6)) as outer_ring
      FROM ST_DumpRings($3)
      where path[1] = 0 
    ),
    array(
      --all inner rings
      SELECT ST_ExteriorRing(gdi_NoseRemoveCore($1, $2, geom, $4, $5, $6)) as inner_rings
      FROM ST_DumpRings($3)
      WHERE path[1] > 0
    ) 
) as geom
$BODY$
  LANGUAGE sql IMMUTABLE
  COST 100;
COMMENT ON FUNCTION public.gdi_noseremove(character varying, integer, geometry, double precision, double precision, boolean) IS 'Entfernt schmale Nasen und Kerben in Polygongeometrie durch Aufruf von der Funktion gdi_NoseRemoveCore für jeden inneren und äußeren Ring und anschließendes wieder zusammenfügen zu Polygon.';

