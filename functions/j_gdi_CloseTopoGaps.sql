--DROP FUNCTION IF EXISTS public.gdi_CloseTopoGaps(CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, DOUBLE PRECISION);
CREATE OR REPLACE FUNCTION public.gdi_CloseTopoGaps(
  topo_name CHARACTER VARYING,
  schema_name CHARACTER VARYING,
  table_name CHARACTER VARYING,
  topo_geom_column CHARACTER VARYING,
  gap_area_tolerance DOUBLE PRECISION
)
  RETURNS BOOLEAN AS
$BODY$
  DECLARE
    sql text;
    gap RECORD;
    num_edges INTEGER = 2;
    debug BOOLEAN = false;
  BEGIN
    IF debug THEN RAISE NOTICE 'Closing TopoGaps'; END IF;

		-- Fragt jeweils die längste edge aller faces ab, die keine Zuordnung zu Polygonen haben
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
        ' || schema_name || '.' || table_name || ' g ON r.topogeo_id = (g.' || topo_geom_column || ').id JOIN
        ' || topo_name || '.face f ON gap.left_face = f.face_id
      WHERE
        ST_Area(ST_GetFaceGeometry(''' || topo_name || ''', gap.left_face)) < ' || gap_area_tolerance || '
    ';
    IF debug THEN RAISE NOTICE 'Find gaps in topology with sql: %', sql; END IF;

    FOR gap IN EXECUTE sql LOOP
			BEGIN
				IF debug THEN RAISE NOTICE 'Close and log gap covert by % edges at face % by adding it to topogeom id %: % from face % and remove edge %', gap.num_edges, gap.left_face, gap.topogeo_id, gap.geom_topo, gap.right_face, gap.edge_id; END IF;
				-- Fügt die Lücke der Fläche zu, die rechts von der längsten Edge liegt
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

			/*
				-- ToDo
				Wenn die edge, die gelöscht werden soll als next_left/right zu anderen edges in Beziehung
				steht, für die betroffenen edges neue Nachbarn finden und auch in abs_next_left/right... setzen.
					update edge_data e
					set next_left_edge = (select ed.edge_id from edge_data ed WHERE ed.next_right_edge = del.edge_id * -1),
					abs_next_left_edge = (select ed.edge_id from edge_data ed WHERE ed.next_right_edge = del.edge_id * -1)
					FROM (select edge_id from edge_data where abs_next_left_edge = 14186) del
					WHERE
					 e.edge_id = del.edge_id

					update edge_data e
					set next_left_edge = (select ed.edge_id from edge_data ed WHERE ed.next_right_edge = del.edge_id * -1),
					abs_next_left_edge = (select ed.edge_id from edge_data ed WHERE ed.next_right_edge = del.edge_id * -1)
					FROM (select edge_id from edge_data where abs_next_right_edge = 14186) del
					WHERE
					 e.edge_id = del.edge_id
*/


-- löscht die längste Edge
				sql = 'SELECT topology.ST_RemEdgeModFace(''' || topo_name || ''', ' || gap.edge_id || ')';
				IF debug THEN RAISE NOTICE 'Execute sql to remove edge: %', sql; END IF;
				EXECUTE sql;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Closing of Gaps failed: %', SQLERRM;
      END;

    END LOOP;
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_CloseTopoGaps(CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, DOUBLE PRECISION) IS 'Entfernt faces < als gap_area_tolerance, die keine Relation zu Polygonen haben, also Lücken zwischen anderen darstellen und ordnet die Fläche dem benachbarten Face und damit Polygon zu, welches die längste Kante an der Lücke hat.';

-- Function: public.gdi_closetopogap(character varying, character varying, character varying, character varying, integer)

-- DROP FUNCTION public.gdi_closetopogap(character varying, character varying, character varying, character varying, integer);

CREATE OR REPLACE FUNCTION public.gdi_closetopogap(
    topo_name character varying,
    schema_name character varying,
    table_name character varying,
    topo_geom_column character varying,
    face_id integer)
  RETURNS boolean AS
$BODY$
  DECLARE
    sql text;
    gap RECORD;
    num_edges INTEGER = 2;
    debug BOOLEAN = false;
  BEGIN
    IF debug THEN RAISE NOTICE 'Closing TopoGap for face_id: %', face_id; END IF;

		-- Fragt jeweils die längste edge aller faces ab, die keine Zuordnung zu Polygonen haben
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
            ed.left_face > 0 AND
            ed.left_face = ' || face_id || '
          ORDER BY left_face, length DESC
        ) gap JOIN
        ' || topo_name || '.relation r ON gap.right_face = r.element_id JOIN
        ' || schema_name || '.' || table_name || ' g ON r.topogeo_id = (g.' || topo_geom_column || ').id JOIN
        ' || topo_name || '.face f ON gap.left_face = f.face_id
    ';
    IF debug THEN RAISE NOTICE 'Find gaps in topology with sql: %', sql; END IF;

    FOR gap IN EXECUTE sql LOOP
			BEGIN
				IF debug THEN RAISE NOTICE 'Close and log gap covert by % edges at face % by adding it to topogeom id %: % from face % and remove edge %', gap.num_edges, gap.left_face, gap.topogeo_id, gap.geom_topo, gap.right_face, gap.edge_id; END IF;
				-- Fügt die Lücke der Fläche zu, die rechts von der längsten Edge liegt
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
				-- löscht die längste Edge
				sql = 'SELECT topology.ST_RemEdgeModFace(''' || topo_name || ''', ' || gap.edge_id || ')';
				IF debug THEN RAISE NOTICE 'Execute sql to remove edge: %', sql; END IF;
				EXECUTE sql;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Closing of Gaps failed: %', SQLERRM;
      END;

    END LOOP;
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION public.gdi_closetopogap(character varying, character varying, character varying, character varying, integer)
  OWNER TO postgres;
COMMENT ON FUNCTION public.gdi_closetopogap(character varying, character varying, character varying, character varying, integer) IS 'Entfernt das face mit face_id, wenn es keine Relation zu Polygonen hat und ordnet die Fläche dem benachbarten Face und damit Polygon zu, welches die längste Kante an der Lücke hat.';
