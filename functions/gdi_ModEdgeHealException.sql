--DROP FUNCTION IF EXISTS public.gdi_ModEdgeHealException(character varying, integer, integer);
CREATE OR REPLACE FUNCTION public.gdi_ModEdgeHealException(
    atopology character varying,
    anedge integer,
    anotheredge integer)
  RETURNS integer AS
$BODY$
DECLARE
  node_id INTEGER;
BEGIN
  SELECT ST_ModEdgeHeal($1, $2 , $3) INTO node_id;
  RETURN node_id;
EXCEPTION WHEN others THEN
  RETURN 0;
END;
$BODY$
LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_ModEdgeHealException(character varying, integer, integer) IS 'Führt zwei benachbarte Kanten zu einer zusammen, wenn von dem Knoten dazwischen keine weiter';