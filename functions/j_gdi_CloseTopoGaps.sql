--DROP FUNCTION IF EXISTS public.gdi_CloseTopoGaps(CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING);
CREATE OR REPLACE FUNCTION public.gdi_CloseTopoGaps(
  topo_name CHARACTER VARYING,
  schema_name CHARACTER VARYING,
  table_name CHARACTER VARYING,
  topo_geom_column CHARACTER VARYING)
  RETURNS BOOLEAN AS
$BODY$
  DECLARE
    sql text;
    gap RECORD;
    num_edges INTEGER = 2;
    debug BOOLEAN = false;
  BEGIN
    IF debug THEN RAISE NOTICE 'Closing TopoGaps'; END IF;

    sql = '
      SELECT
        gap.edge_id,
        g.' || topo_geom_column || ' AS geom_topo,
        gap.left_face,
        gap.right_face,
        num_edges,
        r.topogeo_id
      FROM
        (
          SELECT DISTINCT ON (left_face)
            edge_id,
            left_face,
            right_face,
            St_Length(geom) AS length,
            count(edge_id) OVER (PARTITION BY left_face) AS num_edges
          FROM
            ' || topo_name || '.edge_data ed LEFT JOIN
            ' || topo_name || '.relation rl ON ed.left_face = rl.element_id
          WHERE
            rl.element_id IS NULL AND
            ed.left_face > 0
          ORDER BY left_face, length DESC
        ) gap JOIN
        ' || topo_name || '.relation r ON gap.right_face = r.element_id JOIN
        ' || schema_name || '.' || table_name || ' g ON r.topogeo_id = (g.' || topo_geom_column || ').id 
    ';
    IF debug THEN RAISE NOTICE 'Find gaps in topology with sql: %', sql; END IF;

    FOR gap IN EXECUTE sql LOOP
      IF debug THEN RAISE NOTICE 'Close and log gap covert by % edges at face % by adding it to topogeom id %: % from face % and remove edge %', gap.num_edges, gap.left_face, gap.topogeo_id, gap.geom_topo, gap.right_face, gap.edge_id; END IF;
      sql = '
        INSERT INTO ' || topo_name || '.filled_gaps (polygon_id, face_id, num_edges, face_geom)
        SELECT
          polygon_id,
          face_id,
          num_edges,
          face_geom
        FROM
          (
            SELECT
              polygon_id,
              ' || gap.left_face  || ' AS face_id,
              ' || gap.num_edges || ' AS num_edges,
              topology.ST_GetFaceGeometry(''' || topo_name || ''', ' || gap.left_face || ') AS face_geom,
              topology.TopoGeom_addElement(' || topo_geom_column || ', ARRAY[' || gap.left_face || ', 3]::topology.TopoElement)
            FROM
              ' || schema_name || '.' || table_name || '
            WHERE
              (' || topo_geom_column || ').id = ' || gap.topogeo_id || '
          ) AS gaps_table
      ';
      IF debug THEN RAISE NOTICE 'Execute sql to add the face: %', sql; END IF;
      EXECUTE sql;

      sql = 'SELECT topology.ST_RemEdgeModFace(''' || topo_name || ''', ' || gap.edge_id || ')';
      IF debug THEN RAISE NOTICE 'Execute sql to remove edge: %', sql; END IF;
      EXECUTE sql;

    END LOOP;
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_CloseTopoGaps(CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING) IS 'Entfernt faces, die keine Relation zu Polygonen haben, also Lücken zwischen anderen darstellen und ordnet die Fläche dem benachbarten Face und damit Polygon zu, welches die längste Kante an der Lücke hat.';