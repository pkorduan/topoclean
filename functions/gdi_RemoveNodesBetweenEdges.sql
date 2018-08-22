--DROP FUNCTION gdi_RemoveNodesBetweenEdges(CHARACTER VARYING);
CREATE OR REPLACE FUNCTION gdi_RemoveNodesBetweenEdges(
  topo_name CHARACTER VARYING
)
RETURNS BOOLEAN AS
$BODY$
  DECLARE
    sql text;
    num_nodes INTEGER = 1;
    debug BOOLEAN = false;
  BEGIN
    WHILE num_nodes > 0 LOOP
      EXECUTE '
        WITH node_id_rows AS (
          INSERT INTO ' || topo_name || '.removed_nodes (node_id, geom)
          SELECT
            removed_nodes.node_id,
            geom
          FROM
            (
              SELECT
                gdi_ModEdgeHealException(''' || topo_name || ''', edge_left_id, edge_right_id) node_id
              FROM
                (
                  SELECT abs_next_left_edge edge_left_id, edge_id edge_right_id FROM ' || topo_name || '.edge_data
                  UNION
                  SELECT edge_id edge_left_id, abs_next_right_edge edge_right_id FROM ' || topo_name || '.edge_data
                ) edges
            ) removed_nodes JOIN
            ' || topo_name || '.node ON removed_nodes.node_id = node.node_id
          WHERE
            removed_nodes.node_id > 0
          RETURNING removed_nodes.node_id
        )
        SELECT count(*) FROM node_id_rows
      ' INTO num_nodes;
      RAISE NOTICE 'Anzahl gelöschter Nodes: % ', num_nodes;
    END LOOP;
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION gdi_RemoveNodesBetweenEdges(CHARACTER VARYING) IS 'Die Funktion entfernt alle überflüssigen Knoten, die nur von zwei Kanten begrenzt werden, die selber kein eigenes Face bilden.';