--DROP FUNCTION IF EXISTS public.gdi_CleanPolygonTopo(character varying, character varying, character varying, character varying, DOUBLE PRECISION, INTEGER);
CREATE OR REPLACE FUNCTION public.gdi_CleanPolygonTopo(
  topo_name CHARACTER VARYING,
  schema_name CHARACTER VARYING,
  table_name character varying,
  geom_column CHARACTER VARYING,
  area_tolerance DOUBLE PRECISION,
  polygon_id INTEGER
)
RETURNS BOOLEAN AS
$BODY$
  DECLARE
    sql text;
    small_face Record;
    node RECORD;
    i INTEGER;
    node_id INTEGER;
    nodes INTEGER[];
    debug BOOLEAN = false;
  BEGIN
    -- Remove all edges without relations to faces
    sql = 'SELECT topology.ST_RemEdgeModFace(''' || topo_name || ''', edge_id) FROM ' || topo_name || '.edge_data WHERE right_face = 0 and left_face = 0';
    EXECUTE sql;

    -- query small closed faces of polygon with polygon_id (same start_ and end_node)
    sql = '
      SELECT
        faces.face_id
      FROM
        (
          SELECT
            (topology.GetTopoGeomElements(' || geom_column || '))[1] AS face_id,
            topology.ST_GetFaceGeometry(''' || topo_name || ''', (topology.GetTopoGeomElements(' || geom_column || '))[1]) AS geom
          FROM
            ' || schema_name || '.' || table_name || '
          WHERE
            polygon_id = ' || polygon_id || '
        ) faces JOIN
        ' || topo_name || '.edge_data e ON faces.face_id = e.left_face OR faces.face_id = e.right_face 
      WHERE
        e.start_node = e.end_node AND
        ST_Area(faces.geom) < ' || area_tolerance || '
    ';
    IF debug THEN RAISE NOTICE 'Query small faces with sql: % ', sql; END IF;
    FOR small_face IN EXECUTE sql LOOP
      -- Frage vorher schon mal alle nodes des faces ab, weil die nach dem löschen des face schlechter zufinden sind.
      sql = '
        WITH edges AS (
        SELECT
          start_node, end_node
        FROM
          ' || topo_name || '.edge
        WHERE
          left_face = ' || small_face.face_id || ' OR right_face = ' || small_face.face_id || '
        )
        SELECT start_node AS node_id FROM edges UNION
        SELECT end_node AS node_id FROM edges;
      ';
      i = 1;
      FOR node IN EXECUTE sql LOOP
        nodes[i] = node.node_id;
        i = i + 1;
      END LOOP;

      -- Entferne face von TopoGeom des features
      RAISE NOTICE 'Entferne zu kleines face % from Polygon with polygon_id %', small_face_id, polygon_id;
      EXECUTE 'SELECT topology.TopoGeom_remElement(' || geom_column || ', Array[' || small_face.face_id || ', 3]::topology.TopoElement) FROM ' || table_name || ' WHERE polygon_id = ' || polygon_id;

      -- Entferne alle edges des face aus der Topology und damit auch das face
      EXECUTE 'SELECT topology.ST_RemEdgeModFace(''' || topo_name || ''', abs((topology.ST_GetFaceEdges(''' || topo_name || ''', ' || small_face.face_id || ')).edge))';

      FOREACH node_id IN ARRAY nodes LOOP
        EXECUTE 'SELECT topology.ST_RemoveIsoNode(''' || topo_name || ''', ' || node_id || ')';
      END LOOP;
    END LOOP;

    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_CleanPolygonTopo(character varying, character varying, character varying, character varying, double precision, integer) IS 'Entfernt alle edges ohne Relation zu Polygonen (Ja das kann es geben bei der Erzeugung von TopoGeom.) und löscht Faces des Polygon mit polygon_id, die kleiner als die angegebene area_tolerance in Quadratmetern sind.';
