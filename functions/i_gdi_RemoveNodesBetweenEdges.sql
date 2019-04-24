--DROP FUNCTION public.gdi_RemoveNodesBetweenEdges(CHARACTER VARYING);
CREATE OR REPLACE FUNCTION public.gdi_RemoveNodesBetweenEdges(
  topo_name CHARACTER VARYING
)
RETURNS BOOLEAN AS
$BODY$
  DECLARE
    num_nodes INTEGER = 1;
    edges RECORD;
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
      IF debug THEN RAISE NOTICE 'Anzahl gelöschter Nodes Between Edges: % ', num_nodes; END IF;
    END LOOP;
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_RemoveNodesBetweenEdges(CHARACTER VARYING) IS 'Die Funktion entfernt alle überflüssigen Knoten, die nur von zwei Kanten begrenzt werden, die selber kein eigenes Face bilden.';

--DROP FUNCTION public.gdi_RemoveNodesBetweenEdges(CHARACTER VARYING, BOOLEAN);
CREATE OR REPLACE FUNCTION public.gdi_RemoveNodesBetweenEdges(
  topo_name CHARACTER VARYING,
  skip_error BOOLEAN
)
RETURNS BOOLEAN AS
$BODY$
  DECLARE
    num_nodes INTEGER = 1;
    node RECORD;
    err_msg text;
    debug BOOLEAN = false;
  BEGIN
    IF skip_error THEN
      WHILE num_nodes > 0 LOOP
        num_nodes = 0;
        FOR node IN EXECUTE FORMAT('
          SELECT
            node_id, geom, min(edge_id) left_edge_id, max(edge_id) right_edge_id
          FROM
            (
            	SELECT node_id, geom, abs((GetNodeEdges(%1$L, node_id)).edge) edge_id
            	FROM %1$I.node
            ) edges
          GROUP BY node_id, geom
          HAVING count(edge_id) = 2 AND min(edge_id) != max(edge_id)
        ', topo_name)
        LOOP
          num_nodes = num_nodes + 1;
          BEGIN
            EXECUTE FORMAT('
              SELECT topology.ST_ModEdgeHeal(%1$L, min(edge), max(edge))
              FROM (SELECT abs((GetNodeEdges(%1$L, %2$s)).edge) edge) AS edges
            ',  topo_name, node.node_id);

            EXECUTE FORMAT(
              'INSERT INTO %1$I.removed_nodes (node_id, geom) VALUES (%2$s, %3$L)',
              topo_name, node.node_id, node.geom
            );
          EXCEPTION WHEN OTHERS THEN
            err_msg = FORMAT(
              'EdgeHeal failed between edges %s and %s. Error: %s',
              node.left_edge_id, node.right_edge_id, SQLERRM
            );
            EXECUTE FORMAT(
              'INSERT INTO %1$I.removed_nodes (node_id, geom, err_msg) VALUES (%2$s, %3$L, %4$L)',
              topo_name, node.node_id, node.geom, err_msg
            );

            RAISE WARNING '%s', err_msg;
          END;
        END LOOP;
      END LOOP;
    ELSE
      EXECUTE FORMAT('SELECT gdi_RemoveNodesBetweenEdges(''%s'')', topo_name);
    END IF;

    RETURN TRUE;
  END;
$BODY$
LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_RemoveNodesBetweenEdges(CHARACTER VARYING, BOOLEAN) IS 'Die Funktion entfernt alle überflüssigen Knoten, die nur von zwei Kanten begrenzt werden, die selber kein eigenes Face bilden. Fehler werden übersprungen wenn skip_error is true.';