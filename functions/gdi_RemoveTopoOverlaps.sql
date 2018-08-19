--DROP FUNCTION public.gdi_RemoveTopoOverlaps(character varying, character varying, character varying, character varying, character varying, character varying);
CREATE OR REPLACE FUNCTION public.gdi_RemoveTopoOverlaps(
    topo_name character varying,
    schema_name character varying,
    table_name character varying,
    id_column character varying,
    geom_column character varying,
    topo_geom_column character varying)
  RETURNS boolean AS
$BODY$
  DECLARE
    sql text;
    polygon RECORD;
    debug BOOLEAN = false;
  BEGIN
    -- Finde alle Polygone, die mehr als eine 
    sql = '
      SELECT
        t.' || id_column || ' AS id,
        r.topogeo_id,
        ST_Area(t.' || geom_column || '),
        count(topogeo_id)
      FROM
        ' || schema_name || '.' || table_name || ' t JOIN
        ' || topo_name || '.relation r ON (t.' || topo_geom_column || ').id = r.topogeo_id
      GROUP BY t.' || id_column || ', r.topogeo_id, ST_Area(t.' || geom_column || ')
      HAVING count(r.topogeo_id) > 1
      ORDER BY ST_Area(t.' || geom_column || ')
    ';
    IF debug THEN RAISE NOTICE 'Finde sich überlappende faces in schema: % tabelle: % mit sql: %', schema_name, table_name, sql; END IF;

    FOR polygon IN EXECUTE sql LOOP
      RAISE NOTICE 'Remove and log overlaping faces for polygon_id %', polygon.id;
      sql = '
        INSERT INTO ' || topo_name || '.removed_overlaps (polygon_id, face_id, face_geom)
        SELECT
          ' || polygon.id || ',
          face_id,
          face_geom
        FROM
          (
            SELECT
              r1.element_id face_id,
              ST_GetFaceGeometry(''' || topo_name || ''', r1.element_id) AS face_geom,
              TopoGeom_remElement(t1.' || topo_geom_column || ', ARRAY[r1.element_id, 3]::topology.TopoElement)
            FROM
              ' || topo_name  || '.relation r1 JOIN
              ' || topo_name  || '.relation r2 ON r1.element_id = r2.element_id JOIN
              ' || schema_name  || '.' || table_name || ' t1 ON r1.topogeo_id = (t1.' || topo_geom_column || ').id JOIN
              ' || schema_name  || '.' || table_name || ' t2 ON r2.topogeo_id = (t2.' || topo_geom_column || ').id
            WHERE
              r1.topogeo_id != r2.topogeo_id AND
              r2.topogeo_id = ' || polygon.topogeo_id || '
          ) AS overlaps_table
      ';
      IF debug THEN RAISE NOTICE 'Execute sql: % to remove the faces of polygon: %', sql, polygon.id; END IF;
      EXECUTE sql;

      sql = '
        SELECT
          ST_RemEdgeModFace(''' || topo_name || ''', e.edge_id)
        FROM
          ' || topo_name || '.edge_data e JOIN
          ' || topo_name || '.relation r1 ON e.left_face = r1.element_id JOIN
          ' || topo_name || '.relation r2 ON e.right_face = r2.element_id AND r1.topogeo_id = r2.topogeo_id
        WHERE
          r1.topogeo_id = ' || polygon.topogeo_id || '
      ';
      if debug THEN RAISE NOTICE 'Execute sql: % to remove edges in polygon: %', sql, polygon.id; END IF;
      EXECUTE sql;

      sql = '
        SELECT
          ST_RemoveIsoNode(''' || topo_name || ''', node_id)
        FROM
          ' || topo_name || '.relation r JOIN
          ' || topo_name || '.node n ON r.element_id = n.containing_face
        WHERE
          r.topogeo_id = ' || polygon.topogeo_id || '
      ';
      if debug THEN RAISE NOTICE 'Execute sql: % to remove isolated nodes in polygon: %', sql, polygon.id; END IF;
      EXECUTE sql;

    END LOOP;
    RETURN TRUE;
  END;
$BODY$
LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_RemoveTopoOverlaps(character varying, character varying, character varying, character varying, character varying, character varying) IS 'Entfernt Faces, die zu mehr als einer Topo-Geometrie zugeordnet sind durch Löschen der Face-Zuordnungen und schließlich dem Zuschlagen des Faces durch Löschen der Edges zwischen der Überlappung und der Fläche, der es zugeschlagen wird.';