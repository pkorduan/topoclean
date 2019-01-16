CREATE OR REPLACE FUNCTION public.gdi_logsql(
    func character varying,
    step character varying,
    sql text)
  RETURNS boolean AS
$BODY$
  DECLARE
    debug BOOLEAN = false;
  BEGIN
    IF debug THEN
      EXECUTE 'INSERT INTO sql_logs (func, step, sql) VALUES ($1, $2, $3)'
      USING func, step, sql;
    END IF;
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;-- DROP FUNCTION public.gdi_FilterRings(geometry, double precision);
CREATE OR REPLACE FUNCTION public.gdi_FilterRings(
  polygon geometry,
  area_tolerance double precision
)
RETURNS geometry AS
$BODY$
 SELECT ST_Collect( CASE WHEN d.inner_rings is NULL OR NOT st_within(st_collect(d.inner_rings), ST_MakePolygon(c.outer_ring)) THEN ST_MakePolygon(c.outer_ring) ELSE ST_MakePolygon(c.outer_ring, d.inner_rings) END) as final_geom		-- am 20.07.2016 angepasst
  FROM (/* Get outer ring of polygon */
        SELECT ST_ExteriorRing(b.the_geom) as outer_ring
          FROM (SELECT (ST_DumpRings((ST_Dump($1)).geom)).geom As the_geom, path(ST_DumpRings((ST_Dump($1)).geom)) as path) b
          WHERE b.path[1] = 0 /* ie the outer ring */
        ) c,
       (/* Get all inner rings > a particular area */
        SELECT ST_Accum(ST_ExteriorRing(b.the_geom)) as inner_rings
          FROM (SELECT (ST_DumpRings((ST_Dump($1)).geom)).geom As the_geom, path(ST_DumpRings((ST_Dump($1)).geom)) as path) b
          WHERE b.path[1] > 0 /* ie not the outer ring */
            AND ST_Area(b.the_geom) > $2
        ) d
 $BODY$
  LANGUAGE sql IMMUTABLE
  COST 100;
COMMENT ON FUNCTION public.gdi_FilterRings(geometry, DOUBLE PRECISION) IS 'Remove inner rings of polygon with area <= area_tolerance.';

-- DROP FUNCTION public.gdi_fingercut(geometry, double precision);
CREATE OR REPLACE FUNCTION public.gdi_fingercut(
    poly geometry,
    distance_tolerance double precision)
  RETURNS geometry AS
$BODY$
  DECLARE
    newpoly geometry;
  BEGIN
    -- cut outer fingers
    poly = ST_Intersection(
      poly,
      ST_Buffer(
        ST_Buffer(
          poly,
          -1 * distance_tolerance,
          1
        ),
        1.5 * distance_tolerance,
        1
      )
    );
    -- invert Polygon
    poly = ST_Difference(
      ST_Expand(poly, 10 * distance_tolerance),
      poly
    );
    -- cut inner fingers
    poly = ST_Intersection(
      poly,
      ST_Buffer(
        ST_Buffer(
          poly,
          -1 * distance_tolerance,
          1
        ),
        1.5 * distance_tolerance,
        1
      )
    );
    -- reinvert polygon
    poly = ST_Difference(
      ST_Expand(poly, -5 * distance_tolerance),
      poly
    );

    RETURN poly;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_fingercut(geometry, double precision) IS 'Cut outer and inner finger of a multi or polygon with a given distance_tolerance.';

-- DROP FUNCTION public.gdi_noseremovecore(character varying, integer, geometry, double precision, double precision, boolean);
CREATE OR REPLACE FUNCTION public.gdi_noseremovecore(
    topo_name character varying,
    polygon_id integer,
    geometry,
    angle_tolerance double precision,
    distance_tolerance double precision,
    debug boolean)
  RETURNS geometry AS
$BODY$
DECLARE
  ingeom    alias for $3;
  lineusp geometry;
  linenew geometry;
  newgeom geometry;
  testgeom varchar;
  remove_point boolean;
  removed_point_geom geometry;
  newb boolean;
  changed boolean;
  point_id integer;
  numpoints integer;
  angle_in_point double precision;
  angle_tolerance_arc double precision;
  distance_to_next_point FLOAT;
  num_loop INTEGER;
BEGIN

  angle_tolerance_arc = angle_tolerance / 200 * PI();
  -- input geometry or rather set as default for the output 
  newgeom := ingeom;

  IF debug THEN RAISE NOTICE 'Start function gdi_NoseRemoveCore für polygon_id %', polygon_id; END IF;
  -- check polygon
  if (select ST_GeometryType(ingeom)) = 'ST_Polygon' then
    IF (debug) THEN RAISE NOTICE 'ingeom is of type ST_Polygon'; END IF;
    IF (SELECT ST_NumInteriorRings(ingeom)) = 0 then
      IF (debug) THEN RAISE NOTICE 'num interior ring is 0'; END IF;
      --save the polygon boundary as a line
      lineusp := ST_Boundary(ingeom) as line;
      -- number of tags
      numpoints := ST_NumPoints(lineusp);
      IF (numpoints > 4) THEN
        -- it has more vertex as a triangle which have 4 points (last ist identitcally with first point)
        IF (debug) THEN RAISE NOTICE 'num points of the line: %', numpoints; END IF;
        -- default value of the loop indicates if the geometry has been changed 
        newb := true;  
        -- globale changevariable 
        changed := false;
				num_loop = 1;
        -- loop (to remove several points)
        WHILE newb = true loop
					IF false THEN RAISE NOTICE 'Polygon_id: %, Durchlauf: %', polygon_id, num_loop; END IF;
          -- default values
          remove_point := false;
          newb := false;
          point_id := 1;
          numpoints := ST_NumPoints(lineusp) - 1;
          IF (numpoints > 3) THEN
            -- it has more vertex as a triangle which have 4 points (here counted reduced by 1)
            -- the geometry passes pointwisely until spike has been found and point removed
            WHILE (point_id <= numpoints) AND (remove_point = false) LOOP
              -- the check of the angle at the current point of a spike including the special case, that it is the first point.
                angle_in_point = (
                select
                  abs(
                    pi() -
                    abs(
                      ST_Azimuth(
                        ST_PointN(lineusp, case when point_id = 1 then -2 else point_id - 1 end), 
                        ST_PointN(lineusp, point_id)
                      ) -
                      ST_Azimuth(
                        ST_PointN(lineusp, point_id),
                        ST_PointN(lineusp, point_id + 1)
                      )
                    )
                  )
              );
              distance_to_next_point = (
                SELECT ST_Distance(
                  ST_PointN(lineusp, point_id),
                  ST_PointN(lineusp, point_id + 1)
                )
              );
              IF false THEN RAISE NOTICE 'P: %, d: %, ß: %, a in P % (%): %, a in P % (%): %',
                point_id,
                distance_to_next_point,
                angle_in_point,
                case when point_id = 1 then numpoints else point_id - 1 end,
                ST_AsText(ST_PointN(lineusp, case when point_id = 1 then -2 else point_id - 1 end)),
                ST_Azimuth(
                  ST_PointN(lineusp, case when point_id = 1 then -2 else point_id - 1 end), 
                  ST_PointN(lineusp, point_id)
                ),
                point_id,
                ST_AsText(ST_PointN(lineusp, point_id)),
                ST_Azimuth(
                  ST_PointN(lineusp, point_id),
                  ST_PointN(lineusp, point_id + 1)
                );
              END IF;

              IF angle_in_point < angle_tolerance_arc OR distance_to_next_point < distance_tolerance then
                -- remove point
                removed_point_geom = ST_PointN(lineusp, point_id); -- ST_PointN is 1 based
                linenew := ST_RemovePoint(lineusp, point_id - 1); -- ST_RemovePoint is 0 based

                IF linenew is not null THEN
                  if debug THEN RAISE NOTICE '---> point % removed (%)', point_id, ST_AsText(removed_point_geom); END IF;
                  EXECUTE '
                    INSERT INTO ' || topo_name || '.removed_spikes (polygon_id, geom) VALUES
                      (' || polygon_id || ', ''' || removed_point_geom::text || ''')
                  ';
                  lineusp := linenew;
                  remove_point := true;

                  -- if the first point is concerned, the last point must also be changed to close the line again.
                  IF point_id = 1 THEN
                    -- first point of lineusp is yet at former position 2
                    -- replace last point by new first point 
                    linenew := ST_SetPoint(lineusp, -1, ST_StartPoint(lineusp)); -- ST_SetPoint is 0-based
                    lineusp := linenew;
                  END IF;
                END IF;
              END IF;
              point_id = point_id + 1;
            END LOOP; -- end of pointwisely loop to remove a spike
          END IF;

          -- remove point
          IF remove_point = true then
            numpoints := ST_NumPoints(lineusp);
            newb := true;
            point_id := 0;
            changed := true;
          END IF; -- point has been removed
					num_loop = num_loop + 1;
        END LOOP; -- end of loop to remove several points

        --with the change it is tried to change back the new line geometry in a polygon. if this is not possible, the existing geometry is used
        IF changed = true then
          IF debug THEN RAISE NOTICE 'New line geom %', ST_AsText(lineusp); END IF;
          IF NOT ST_IsClosed(lineusp) THEN
            RAISE NOTICE '---> Close non-closed line by adding StartPoint % at the end of the line.', ST_AsText(ST_StartPoint(lineusp));
            lineusp = ST_AddPoint(lineusp, ST_StartPoint(lineusp));
          END IF;
          newgeom :=  ST_BuildArea(lineusp) as geom;
          -- errorhandling
          IF newgeom is not null THEN
            IF debug THEN RAISE NOTICE 'new geometry created!'; END IF;
          ELSE
            newgeom := ingeom;
            RAISE NOTICE '-------------- area could not be created !!! --------------';
            testgeom := ST_AsText(lineusp);
            raise notice 'geometry %', testgeom;
          END IF; -- newgeom is not null
        END IF; -- geom has been changed
      ELSE
        IF (debug) THEN RAISE NOTICE 'Break loop due to num points of the line is only %', numpoints; END IF;
      END IF; -- ingeom has more than 3 points
    end if; -- ingeom has 0 interior rings
  end if; -- ingeom is of type ST_Polygon
  -- return value
  RETURN newgeom;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_noseremovecore(character varying, integer, geometry, double precision, double precision, boolean) IS 'Entfernt schmale Nasen und Kerben in der Umrandung von Polygonen durch abwechslendes Löschen von Punkten mit Abständen < <distance_tolerance> und von Scheitelpunkten mit spitzen Winkeln < <angle_tolerance> in Gon';

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

-- DROP FUNCTION public.gdi_cleanpolygontopo(character varying, character varying, character varying, character varying, double precision, integer, boolean);

CREATE OR REPLACE FUNCTION public.gdi_cleanpolygontopo(
    topo_name character varying,
    schema_name character varying,
    table_name character varying,
    geom_column character varying,
    area_tolerance double precision,
    polygon_id integer,
    debug boolean)
  RETURNS boolean AS
$BODY$
  DECLARE
    sql text;
    small_face Record;
    node RECORD;
    i INTEGER;
    node_id INTEGER;
    nodes INTEGER[];
		edges RECORD;
  BEGIN
		IF debug THEN RAISE NOTICE 'CleanPolygonTopo for polygon_id: %', polygon_id; END IF;
    -- Remove all edges without relations to faces
    sql = 'SELECT edge_id, topology.ST_RemEdgeModFace(''' || topo_name || ''', edge_id) FROM ' || topo_name || '.edge_data WHERE right_face = 0 and left_face = 0';
    EXECUTE sql
		INTO edges;
		IF debug THEN RAISE NOTICE 'With ST_RemEdgeModFace removed edges: %', edges; END IF;

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
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_cleanpolygontopo(character varying, character varying, character varying, character varying, double precision, integer, boolean) IS 'Entfernt alle edges ohne Relation zu Polygonen (Ja das kann es geben bei der Erzeugung von TopoGeom.) und löscht Faces des Polygon mit polygon_id, die kleiner als die angegebene area_tolerance in Quadratmetern sind.';

--DROP FUNCTION IF EXISTS public.gdi_RemoveTopoOverlaps(character varying, character varying, character varying, character varying, character varying, character varying);
CREATE OR REPLACE FUNCTION public.gdi_RemoveTopoOverlaps(
  topo_name character varying,
  schema_name character varying,
  table_name character varying,
  id_column character varying,
  geom_column character varying,
  topo_geom_column character varying
)
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
      IF debug THEN RAISE NOTICE 'Remove and log overlaping faces for polygon_id %', polygon.id; END IF;
      sql = '
        INSERT INTO ' || topo_name || '.removed_overlaps (removed_face_id, from_polygon_id, for_polygon_id, face_geom)
        SELECT
          removed_face_id,
          from_polygon_id,
          ' || polygon.id || ' AS for_polygon_id,
          face_geom
        FROM
          (
            SELECT
              r1.element_id removed_face_id,
              t1.polygon_id from_polygon_id,
              topology.ST_GetFaceGeometry(''' || topo_name || ''', r1.element_id) AS face_geom,
              topology.TopoGeom_remElement(t1.' || topo_geom_column || ', ARRAY[r1.element_id, 3]::topology.TopoElement)
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
          topology.ST_RemEdgeModFace(''' || topo_name || ''', e.edge_id)
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
          topology.ST_RemoveIsoNode(''' || topo_name || ''', node_id)
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
  SELECT topology.ST_ModEdgeHeal($1, $2 , $3) INTO node_id;
  RETURN node_id;
EXCEPTION WHEN others THEN
  RETURN 0;
END;
$BODY$
LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_ModEdgeHealException(character varying, integer, integer) IS 'Führt zwei benachbarte Kanten zu einer zusammen, wenn von dem Knoten dazwischen keine weiter';

--DROP FUNCTION public.gdi_RemoveNodesBetweenEdges(CHARACTER VARYING);
CREATE OR REPLACE FUNCTION public.gdi_RemoveNodesBetweenEdges(
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
      IF debug THEN RAISE NOTICE 'Anzahl gelöschter Nodes Between Edges: % ', num_nodes; END IF;
    END LOOP;
    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION public.gdi_RemoveNodesBetweenEdges(CHARACTER VARYING) IS 'Die Funktion entfernt alle überflüssigen Knoten, die nur von zwei Kanten begrenzt werden, die selber kein eigenes Face bilden.';--DROP FUNCTION IF EXISTS public.gdi_CloseTopoGaps(CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, DOUBLE PRECISION);
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
        ST_Area(ST_GetFaceGeometry(''' || topo_name || ''', gap.left_face)) < 25000
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
COMMENT ON FUNCTION public.gdi_CloseTopoGaps(CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, CHARACTER VARYING, DOUBLE PRECISION) IS 'Entfernt faces < als gap_area_tolerance, die keine Relation zu Polygonen haben, also Lücken zwischen anderen darstellen und ordnet die Fläche dem benachbarten Face und damit Polygon zu, welches die längste Kante an der Lücke hat.';-- DROP FUNCTION public.gdi_preparepolygontopo(character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean);

CREATE OR REPLACE FUNCTION public.gdi_preparepolygontopo(
    topo_name character varying,
    schema_name character varying,
    table_name character varying,
    id_column character varying,
    geom_column character varying,
    expression_column character varying,
    expression character varying,
    epsg_code integer,
    distance_tolerance double precision,
    angle_tolerance double precision,
    topo_tolerance double precision,
    area_tolerance double precision,
    debug boolean)
  RETURNS boolean AS
$BODY$
  DECLARE
    sql text;
    msg text;
    result RECORD;
    rec record;
    expression_select CHARACTER VARYING = '';
    expression_where CHARACTER VARYING = '';
  BEGIN

    -- Prüfe ob ein topo_name angegeben wurde
    IF topo_name = '' OR topo_name IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die Topographie angegeben werden!';
    END IF;

    -- Ersetze schema_name mit public when leer oder NULL und prüfe ob es das Schema gibt
    IF schema_name = '' OR schema_name IS NULL THEN
      schema_name = 'public';
    END IF;
    EXECUTE 'SELECT schema_name FROM information_schema.schemata WHERE schema_name = ''' || schema_name || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Schema % nicht gefunden!', schema_name;
    END IF;

    -- Prüfe ob ein Tabellenname angegeben wurde und ob es die Tabelle in dem Schema gibt
    IF table_name = '' OR table_name IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Tabellenname angegeben werden!';
    END IF;
    EXECUTE 'SELECT table_name from information_schema.tables WHERE table_schema =  ''' || schema_name || ''' AND table_name = ''' || table_name || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Tabelle % im Schema % nicht gefunden!', table_name, schema_name;
    END IF;

    -- Prüfe ob die id Spalte angegeben worden ist und in der Tabelle vorhanden ist
    IF id_column = '' OR id_column IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die ID-Spalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT column_name from information_schema.columns WHERE table_schema =  ''' || schema_name || ''' AND table_name = ''' || table_name || ''' AND column_name = ''' || id_column || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Spalte % in Tabelle % nicht gefunden!', id_column, table_name;
    END IF;

    -- Prüfe ob die geom Spalte angegeben worden, in der Tabelle vorhanden und vom Geometrietyp Polygon oder MultiPolygon ist
    IF geom_column = '' OR geom_column IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die Geometriespalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT type FROM geometry_columns WHERE f_table_schema =  ''' || schema_name || ''' AND f_table_name = ''' || table_name || ''' AND f_geometry_column = ''' || geom_column || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Geometriespalte % in Tabelle % nicht gefunden oder nicht vom Typ geometry!', geom_column, table_name;
    END IF;
    IF Position('POLYGON' IN result.type) = 0 THEN
      RAISE EXCEPTION 'Geometriespalte % in Tabelle % ist nicht vom Typ Polygon oder MultiPolygon!', geom_column, table_name;
    END IF;

    -- Prüfe ob die epsg_code Spalte angegeben worden ist und ob es diesen gibt
    IF epsg_code IS NULL THEN
      RAISE EXCEPTION 'Es muss ein EPSG-Code für die zu korrigierende Geometriespalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT srid FROM spatial_ref_sys WHERE srid = ' || epsg_code INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'EPSG-Code % existiert nicht!', epsg_code;
    END IF;

    -- Prüfe ob die distance-Toleranz angegeben worden ist
    IF distance_tolerance = 0 OR distance_tolerance IS NULL THEN
      RAISE EXCEPTION 'Es muss eine Toleranz angegeben werden für die Löschung von zu eng beieinander liegenden Punkten!';
    END IF;

    -- Prüfe ob die Topo-Toleranz angegeben worden ist
    IF topo_tolerance = 0 OR topo_tolerance IS NULL THEN
      RAISE EXCEPTION 'Es muss eine Toleranz angegeben werden für die Bildung der Topologie!';
    END IF;

    -- CREATE TABLE for logging sql
    EXECUTE 'DROP TABLE IF EXISTS sql_logs';
    sql = '
      CREATE UNLOGGED TABLE sql_logs (
        id serial,
        func character varying,
        step character varying,
        sql text,
        CONSTRAINT sql_log_pkey PRIMARY KEY (id)
      )
    ';
    EXECUTE sql;
    if debug THEN RAISE NOTICE 'CREATE TABLE for logging sql with sql: %', sql; END IF;

    -- drop topology
    IF debug THEN RAISE NOTICE 'Drop Topology: %', topo_name; END IF;
    sql = '
      SELECT topology.DropTopology(''' || topo_name || ''')
      WHERE EXISTS (
        SELECT * FROM topology.topology WHERE name = ''' || topo_name || '''
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    -- create topology
    if debug THEN RAISE NOTICE 'Create Topology: %', topo_name; END IF;
    sql = 'SELECT topology.CreateTopology(''' || topo_name || ''', '|| epsg_code || ', ' || topo_tolerance || ')';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    -- CREATE UNLOGGED TABLEs for logging results
    if debug THEN RAISE NOTICE 'CREATE UNLOGGED TABLEs for logging results'; END IF;
    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.intersections';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.intersections (
        step character varying,
        polygon_a_id integer,
        polygon_b_id integer,
        the_geom geometry(MULTIPOLYGON, ' || epsg_code || '),
        CONSTRAINT intersections_pkey PRIMARY KEY (step, polygon_a_id, polygon_b_id)
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_spikes';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_spikes (
        id serial,
        polygon_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        CONSTRAINT removed_spikes_pkey PRIMARY KEY (id)
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_overlaps';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_overlaps (
        removed_face_id integer,
        from_polygon_id integer,
        for_polygon_id integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT removed_overlaps_pkey PRIMARY KEY (removed_face_id, from_polygon_id, for_polygon_id)
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.filled_gaps';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.filled_gaps (
        polygon_id integer,
        face_id integer,
        num_edges integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT filled_gaps_pkey PRIMARY KEY (polygon_id, face_id)
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.statistic';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.statistic (
        nr serial,
        key character varying,
        value double precision,
        description text,
        CONSTRAINT statistic_pkey PRIMARY KEY (nr)
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_nodes';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_nodes (
        node_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        CONSTRAINT removed_nodes_pkey PRIMARY KEY (node_id)
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Prepare Tables', sql); EXECUTE sql;

    IF expression_column IS NOT NULL THEN
      IF expression_column NOT IN (id_column, geom_column, 'err_msg') THEN
        expression_select = expression_column || ',';
      END IF;
      expression_where = ' WHERE ' || expression_column || ' ' || expression;
    END IF;

    if debug THEN RAISE NOTICE 'Write first 7 statistics data'; END IF;
    sql = '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (''Name der Topologie'', NULL, ''' || topo_name || '''),
      (''Ursprüngliche Tabelle'', NULL, '''|| schema_name || '.' || table_name || '''),
      (''Geometriespalte'', NULL, ''' || geom_column || '''),
      (''Distanz Toleranz'', ' || distance_tolerance || ', ''m''),
      (''Angle Toleranz'', ' || angle_tolerance || ', ''m''),
      (''Topology Toleranz'', ' || topo_tolerance || ', ''m'')
      , (''Gesamtfläche vorher'', (SELECT Round(Sum(ST_Area(ST_Transform(' || geom_column || ', ' || epsg_code || '))))/10000 FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''ha'')
      , (''Anzahl Flächen vorher'', (SELECT count(*) FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''Stück'')
      , (''Anzahl Stützpunkte vorher'', (SELECT Sum(ST_NPoints(' || geom_column || ')) FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''Stück'')
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Insert Statistic', sql); EXECUTE sql;
/*
    Das hier fällt erstmal flach, weil die Geometrie vor der Vorverarbeitung noch invalid sein kann und jetzt nur für diese Verschneidung nicht vorab schon mal korrigiert werden soll
    den Aufwand kann man betreiben wenn man an der Statistik interessiert ist wie viel Verschneidungsfäche sich durch die Vorverarbeitung ändert.
    Man müsste die Ausgangsgeometrie noch mal separat zwischenspeichern und indizieren, damit die Verschneidung performant läuft.
    Den Schritt lassen wir erstmal weg.
    RAISE NOTICE 'Calculate Intersections of original geometry in table intersections.';
    EXECUTE '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''vor Polygonaufbereitung'' AS step,
        a.gid AS polygon_a_id,
        b.gid AS polygon_b_id,
        ST_Transform(ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(st_transform(a.the_geom, ' || epsg_code::text || '), st_transform(b.the_geom, ' || epsg_code::text || ')))
            ,3
          )
        ), ' || epsg_code || ') AS the_geom
      FROM
        ' || schema_name || '.' || table_name || ' a JOIN
        ' || schema_name || '.' || table_name || ' b ON ST_Intersects(st_transform(a.the_geom, ' || epsg_code::text || '), st_transform(b.the_geom, ' || epsg_code::text || ')) AND a.gid > b.gid AND NOT ST_Touches(st_transform(a.the_geom, ' || epsg_code::text || '), st_transform(b.the_geom, ' || epsg_code::text || ')) '
      || expression_where || '
      ORDER BY
        a.gid, b.gid
    ';
*/
    IF debug THEN RAISE NOTICE 'Drop table topo_geom in topology schema % if exists.', topo_name; END IF;
    -- create working table for topological corrected polygons
    EXECUTE 'DROP TABLE IF EXISTS ' || topo_name || '.topo_geom';

    sql = FORMAT ('
      CREATE UNLOGGED TABLE %9$I.topo_geom AS
      SELECT
        %7$I,
        %10$s
        %1$I,
        err_msg
      FROM
        (
          SELECT
            %7$I,
            %10$s
            ST_GeometryN(
              geom,
              generate_series(
                1,
                ST_NumGeometries(geom)
              )
            ) AS %1$I,
            ''''::CHARACTER VARYING AS err_msg
          FROM
            (
              SELECT
                %7$I,
                %10$s
                gdi_FilterRings(
                  gdi_FingerCut(
                    ST_CollectionExtract(
                      ST_MakeValid(
                         ST_SimplifyPreserveTopology(
                          ST_Transform(
                            %1$I,
                            %2$s
                          ),
                          %8$L
                        )
                      ),
                      3
                    ),
                    %8$L
                  ),
                  %3$s
                ) AS geom
              FROM
                %4$I.%5$I
              %11$s
            ) foo
        ) bar
        WHERE
          ST_Area(%1$I) > %3$s
        ORDER BY
          %7$I 
      ',
      geom_column, epsg_code, area_tolerance, schema_name, table_name, expression, id_column, distance_tolerance, topo_name, expression_select, expression_where, debug
    );

    IF true THEN RAISE NOTICE 'Create and fill table %.topo_geom with prepared polygons with sql: %', topo_name, sql; END IF;
    PERFORM gdi_logsql('PreparePolygonTopo', 'Make geometry valid, extract Polygons and simplify.', sql); EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Add columns polygon_id, %_topo, %_corrected_geom and indexes', table_name, table_name; END IF;
    BEGIN
      sql = 'CREATE INDEX ' || table_name || '_' || geom_column ||'_gist ON ' || schema_name || '.' || table_name || ' USING gist(' || geom_column || ')';
      PERFORM gdi_logsql('PreparePolygonTopo', 'Create gist index.', sql); EXECUTE sql;
    EXCEPTION
      WHEN duplicate_table
      THEN RAISE NOTICE 'Index: %_%_gist on table: % already exists, skipping!', table_name, geom_column, table_name;
    END;
    sql = 'ALTER TABLE ' || topo_name || '.topo_geom ADD COLUMN polygon_id serial NOT NULL';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'ALTER TABLE ' || topo_name || '.topo_geom ADD CONSTRAINT ' || table_name || '_topo_pkey PRIMARY KEY (polygon_id)';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'CREATE INDEX topo_geom_' || id_column || '_idx ON ' || topo_name || '.topo_geom USING btree (' || id_column || ')';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'CREATE INDEX topo_geom_' || geom_column || '_gist ON ' || topo_name || '.topo_geom USING gist(' || geom_column || ')';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'SELECT topology.AddTopoGeometryColumn(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ''Polygon'')';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Alter topology table.', sql); EXECUTE sql;
    IF debug THEN RAISE NOTICE 'Drop column %_topo_corrected if exists!', geom_column; END IF; 
    sql = 'ALTER TABLE ' || schema_name || '.' || table_name || ' DROP COLUMN IF EXISTS ' || geom_column || '_topo_corrected';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'SELECT AddGeometryColumn(''' || schema_name || ''', ''' || table_name || ''', ''' || geom_column || '_topo_corrected'', ' || epsg_code || ', ''MultiPolygon'', 2)';
    PERFORM gdi_logsql('PreparePolygonTopo', 'Alter topology table.', sql); EXECUTE sql;

    msg = 'Calculate intersections after polygon preparation in table intersections.';
    IF debug THEN RAISE NOTICE '%', msg; END IF;
    sql = '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''nach Polygonaufbereitung'',
        a.polygon_id,
        b.polygon_id,
        ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(a.the_geom, b.the_geom))
            ,3
          )
      )
      FROM
        ' || topo_name || '.topo_geom a JOIN
        ' || topo_name || '.topo_geom b ON ST_Intersects(a.the_geom, b.the_geom) AND a.polygon_id > b.polygon_id AND NOT ST_Touches(a.the_geom, b.the_geom)
      ORDER BY
        a.polygon_id, b.polygon_id
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', msg, sql); EXECUTE sql;

    msg = 'Calculate area of overlapping polygons and write into statistic table.';
    sql = '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der Überlappungen nach Polygonaufbereitung'',
        (
          SELECT Round(Sum(ST_Area(the_geom)))
          FROM ' || topo_name || '.intersections
          WHERE step = ''nach Polygonaufbereitung''
        ),
        ''m2''
      ), (
        ''Gesamtfläche nach Polygonaufbereitung'',
        (
          SELECT
            Round(Sum(ST_Area(' || geom_column || ')))/10000
          FROM
            ' || topo_name || '.topo_geom
        ),
        ''ha''
      ), (
        ''Anzahl der Polygone'', (SELECT count(*) FROM ' || topo_name || '.topo_geom), ''Stück'')
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', msg, sql); EXECUTE sql;

    msg = 'Calculate area difference.';
    sql = '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz nach - vor Polygonaufbereitung'',
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach Polygonaufbereitung'') -
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche vorher''),
        ''m2''
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', msg, sql); EXECUTE sql;

    msg = 'Do NoseRemove and update topo_geom.';
    IF debug THEN RAISE NOTICE '%', msg; END IF;
    sql = '
      UPDATE ' || topo_name || '.topo_geom
      SET ' || geom_column || ' = gdi_NoseRemove(''' || topo_name || ''', polygon_id, ' || geom_column || ', ' || angle_tolerance || ', ' || distance_tolerance || ', ' || debug || ')
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', msg, sql); EXECUTE sql;

    msg = 'Calculate Intersection after NoseRemove in table intersections.';
    IF debug THEN RAISE NOTICE '%', msg; END IF;
    sql = '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''nach NoseRemove'',
        a.polygon_id,
        b.polygon_id,
        ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(a.the_geom, b.the_geom))
            ,3
          )
      )
      FROM
        ' || topo_name || '.topo_geom a JOIN
        ' || topo_name || '.topo_geom b ON ST_Intersects(a.the_geom, b.the_geom) AND a.polygon_id > b.polygon_id AND NOT ST_Touches(a.the_geom, b.the_geom)
      ORDER BY
        a.polygon_id, b.polygon_id
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', msg, sql); EXECUTE sql;

    msg = 'Calc overlap after noseRemove.';
    sql = '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der Überlappungen nach NoseRemove'',
        (
          SELECT Round(Sum(ST_Area(the_geom)))
          FROM ' || topo_name || '.intersections
          WHERE step = ''nach NoseRemove''
        ),
        ''m2''
      ), (
        ''Gesamtfläche nach NoseRemove'',
        (
          SELECT
            Round(Sum(ST_Area(' || geom_column || ')))/10000
          FROM
            ' || topo_name || '.topo_geom
        ),
        ''ha''
      )
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', msg, sql); EXECUTE sql;

    msg = 'Calculate Area difference.';
    sql = '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz nach - vor NoseRemove'',
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach NoseRemove'') -
        (SELECT Round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach Polygonaufbereitung''),
        ''m2''
      );
    ';
    PERFORM gdi_logsql('PreparePolygonTopo', msg, sql); EXECUTE sql;

    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_preparepolygontopo(character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean) IS 'Bereitet die Erzeugung einer Topologie vor in dem die Geometrien der betroffenen Tabelle zunächst in einzelne Polygone zerlegt, transformiert, valide und mit distance_tolerance vereinfacht werden. Die Polygone werden in eine temporäre Tabelle kopiert und dort eine TopGeom Spalte angelegt. Eine vorhandene Topologie und temporäre Tabelle mit gleichem Namen wird vorher gelöscht.';

-- DROP FUNCTION public.gdi_preparetopo(character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean);

CREATE OR REPLACE FUNCTION public.gdi_preparetopo(
    topo_name character varying,
    schema_name character varying,
    table_name character varying,
    id_column character varying,
    geom_column character varying,
    expression_column character varying,
    expression character varying,
    epsg_code integer,
    distance_tolerance double precision,
    angle_tolerance double precision,
    topo_tolerance double precision,
    area_tolerance double precision,
    debug boolean)
  RETURNS boolean AS
$BODY$
  DECLARE
    sql text;
    msg text;
    result RECORD;
    rec record;
    expression_select CHARACTER VARYING = '';
    expression_where CHARACTER VARYING = '';
  BEGIN

    -- Prüfe ob ein topo_name angegeben wurde
    IF topo_name = '' OR topo_name IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die Topographie angegeben werden!';
    END IF;

    -- Ersetze schema_name mit public when leer oder NULL und prüfe ob es das Schema gibt
    IF schema_name = '' OR schema_name IS NULL THEN
      schema_name = 'public';
    END IF;
    EXECUTE 'SELECT schema_name FROM information_schema.schemata WHERE schema_name = ''' || schema_name || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Schema % nicht gefunden!', schema_name;
    END IF;

    -- Prüfe ob ein Tabellenname angegeben wurde und ob es die Tabelle in dem Schema gibt
    IF table_name = '' OR table_name IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Tabellenname angegeben werden!';
    END IF;
    EXECUTE 'SELECT table_name from information_schema.tables WHERE table_schema =  ''' || schema_name || ''' AND table_name = ''' || table_name || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Tabelle % im Schema % nicht gefunden!', table_name, schema_name;
    END IF;

    -- Prüfe ob die id Spalte angegeben worden ist und in der Tabelle vorhanden ist
    IF id_column = '' OR id_column IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die ID-Spalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT column_name from information_schema.columns WHERE table_schema =  ''' || schema_name || ''' AND table_name = ''' || table_name || ''' AND column_name = ''' || id_column || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Spalte % in Tabelle % nicht gefunden!', id_column, table_name;
    END IF;

    -- Prüfe ob die geom Spalte angegeben worden, in der Tabelle vorhanden und vom Geometrietyp Polygon oder MultiPolygon ist
    IF geom_column = '' OR geom_column IS NULL THEN
      RAISE EXCEPTION 'Es muss ein Name für die Geometriespalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT type FROM geometry_columns WHERE f_table_schema =  ''' || schema_name || ''' AND f_table_name = ''' || table_name || ''' AND f_geometry_column = ''' || geom_column || '''' INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'Geometriespalte % in Tabelle % nicht gefunden oder nicht vom Typ geometry!', geom_column, table_name;
    END IF;
    IF Position('POLYGON' IN result.type) = 0 THEN
      RAISE EXCEPTION 'Geometriespalte % in Tabelle % ist nicht vom Typ Polygon oder MultiPolygon!', geom_column, table_name;
    END IF;

    -- Prüfe ob die epsg_code Spalte angegeben worden ist und ob es diesen gibt
    IF epsg_code IS NULL THEN
      RAISE EXCEPTION 'Es muss ein EPSG-Code für die zu korrigierende Geometriespalte in der Tabelle angegeben sein!';
    END IF;
    EXECUTE 'SELECT srid FROM spatial_ref_sys WHERE srid = ' || epsg_code INTO result;
    IF result IS NULL THEN
      RAISE EXCEPTION 'EPSG-Code % existiert nicht!', epsg_code;
    END IF;

    -- Prüfe ob die distance-Toleranz angegeben worden ist
    IF distance_tolerance = 0 OR distance_tolerance IS NULL THEN
      RAISE EXCEPTION 'Es muss eine Toleranz angegeben werden für die Löschung von zu eng beieinander liegenden Punkten!';
    END IF;

    -- Prüfe ob die Topo-Toleranz angegeben worden ist
    IF topo_tolerance = 0 OR topo_tolerance IS NULL THEN
      RAISE EXCEPTION 'Es muss eine Toleranz angegeben werden für die Bildung der Topologie!';
    END IF;

    -- CREATE TABLE for logging sql
    EXECUTE 'DROP TABLE IF EXISTS sql_logs';
    sql = '
      CREATE UNLOGGED TABLE sql_logs (
        id serial,
        func character varying,
        step character varying,
        sql text,
        CONSTRAINT sql_log_pkey PRIMARY KEY (id)
      )
    ';
    EXECUTE sql;
    if debug THEN RAISE NOTICE 'CREATE TABLE for logging sql with sql: %', sql; END IF;

    -- drop topology
    IF debug THEN RAISE NOTICE 'Drop Topology: %', topo_name; END IF;
    sql = '
      SELECT topology.DropTopology(''' || topo_name || ''')
      WHERE EXISTS (
        SELECT * FROM topology.topology WHERE name = ''' || topo_name || '''
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    -- create topology
    if debug THEN RAISE NOTICE 'Create Topology: %', topo_name; END IF;
    sql = 'SELECT topology.CreateTopology(''' || topo_name || ''', '|| epsg_code || ', ' || topo_tolerance || ')';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    -- CREATE UNLOGGED TABLEs for logging results
    if debug THEN RAISE NOTICE 'CREATE UNLOGGED TABLEs for logging results'; END IF;
    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.intersections';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.intersections (
        step character varying,
        polygon_a_id integer,
        polygon_b_id integer,
        the_geom geometry(MULTIPOLYGON, ' || epsg_code || '),
        CONSTRAINT intersections_pkey PRIMARY KEY (step, polygon_a_id, polygon_b_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.next';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.next (
        id character varying
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_spikes';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_spikes (
        id serial,
        polygon_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        CONSTRAINT removed_spikes_pkey PRIMARY KEY (id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_overlaps';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_overlaps (
        removed_face_id integer,
        from_polygon_id integer,
        for_polygon_id integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT removed_overlaps_pkey PRIMARY KEY (removed_face_id, from_polygon_id, for_polygon_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.filled_gaps';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.filled_gaps (
        polygon_id integer,
        face_id integer,
        num_edges integer,
        face_geom geometry(POLYGON, ' || epsg_code || '),
        CONSTRAINT filled_gaps_pkey PRIMARY KEY (polygon_id, face_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.statistic';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.statistic (
        nr serial,
        key character varying,
        value double precision,
        description text,
        CONSTRAINT statistic_pkey PRIMARY KEY (nr)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    sql = 'DROP TABLE IF EXISTS ' || topo_name || '.removed_nodes';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;
    sql = '
      CREATE UNLOGGED TABLE ' || topo_name || '.removed_nodes (
        node_id integer,
        geom geometry(POINT, ' || epsg_code || '),
        CONSTRAINT removed_nodes_pkey PRIMARY KEY (node_id)
      )
    ';
    PERFORM gdi_logsql('preparetopo', 'Prepare Tables', sql); EXECUTE sql;

    IF expression_column IS NOT NULL THEN
      IF expression_column NOT IN (id_column, geom_column, 'err_msg') THEN
        expression_select = expression_column || ',';
      END IF;
      expression_where = ' WHERE ' || expression;
    END IF;

    if debug THEN RAISE NOTICE 'Write first 9 statistics data'; END IF;
    sql = '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (''Name der Topologie'', NULL, ''' || topo_name || '''),
      (''Ursprüngliche Tabelle'', NULL, '''|| schema_name || '.' || table_name || '''),
      (''Geometriespalte'', NULL, ''' || geom_column || '''),
      (''Distanz Toleranz'', ' || distance_tolerance || ', ''m''),
      (''Angle Toleranz'', ' || angle_tolerance || ', ''m''),
      (''Topology Toleranz'', ' || topo_tolerance || ', ''m'')
      , (''Gesamtfläche vorher'', (SELECT Round(Sum(ST_Area(ST_Transform(' || geom_column || ', ' || epsg_code || '))))/10000 FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''ha'')
      , (''Anzahl Flächen vorher'', (SELECT count(*) FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''Stück'')
      , (''Anzahl Stützpunkte vorher'', (SELECT Sum(ST_NPoints(' || geom_column || ')) FROM ' || schema_name || '.' || table_name || ' a' || expression_where || '), ''Stück'')
    ';
    PERFORM gdi_logsql('preparetopo', 'Insert Statistic', sql); EXECUTE sql;

    sql = FORMAT ('
      CREATE UNLOGGED TABLE %1$I.topo_geom AS
      SELECT
        %2$I,
        %3$s
        ST_Transform(%4$I, %7$s) AS the_geom,
        NULL::text AS err_msg
      FROM
        %5$I.%6$I
      WHERE
        false
      ',
      topo_name, id_column, expression_select, geom_column, schema_name, table_name, epsg_code
    );
    IF true THEN RAISE NOTICE 'Create table %.topo_geom for prepared polygons with sql: %', topo_name, sql; END IF;
    PERFORM gdi_logsql('preparetopo', 'Create topo geom table.', sql); EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Add columns polygon_id, %_topo, %_corrected_geom and indexes', table_name, table_name; END IF;
    BEGIN
      sql = 'CREATE INDEX ' || table_name || '_' || geom_column ||'_gist ON ' || schema_name || '.' || table_name || ' USING gist(' || geom_column || ')';
      PERFORM gdi_logsql('preparetopo', 'Create gist index.', sql); EXECUTE sql;
    EXCEPTION
      WHEN duplicate_table
      THEN RAISE NOTICE 'Index: %_%_gist on table: % already exists, skipping!', table_name, geom_column, table_name;
    END;
    sql = 'ALTER TABLE ' || topo_name || '.topo_geom ADD COLUMN polygon_id serial NOT NULL';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'ALTER TABLE ' || topo_name || '.topo_geom ADD CONSTRAINT ' || table_name || '_topo_pkey PRIMARY KEY (polygon_id)';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'CREATE INDEX topo_geom_' || id_column || '_idx ON ' || topo_name || '.topo_geom USING btree (' || id_column || ')';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'CREATE INDEX topo_geom_' || geom_column || '_gist ON ' || topo_name || '.topo_geom USING gist(' || geom_column || ')';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;
    sql = 'SELECT topology.AddTopoGeometryColumn(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ''Polygon'')';
    PERFORM gdi_logsql('preparetopo', 'Alter topology table.', sql); EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Replace column %_topo_corrected if exists!', geom_column; END IF; 
    sql = 'ALTER TABLE ' || schema_name || '.' || table_name || ' DROP COLUMN IF EXISTS ' || geom_column || '_topo_corrected';
    PERFORM gdi_logsql('preparetopo', 'Drop column for corrected geom to geometry table.', sql); EXECUTE sql;
    sql = 'SELECT AddGeometryColumn(''' || schema_name || ''', ''' || table_name || ''', ''' || geom_column || '_topo_corrected'', ' || epsg_code || ', ''MultiPolygon'', 2)';
    PERFORM gdi_logsql('preparetopo', 'Add column for corrected geom to geometry table.', sql); EXECUTE sql;

    IF debug THEN RAISE NOTICE 'Replace column %_msg if exists!', geom_column; END IF; 
    sql = 'ALTER TABLE ' || schema_name || '.' || table_name || ' DROP COLUMN IF EXISTS ' || geom_column || '_msg';
    PERFORM gdi_logsql('preparetopo', 'Drop column for msg in geometry table.', sql); EXECUTE sql;
    sql = 'ALTER TABLE ' || schema_name || '.' || table_name || ' ADD COLUMN ' || geom_column || '_msg text';
    PERFORM gdi_logsql('preparetopo', 'Add column for msg in geometry table.', sql); EXECUTE sql;

    RETURN TRUE;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_preparetopo(character varying, character varying, character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, boolean) IS 'Prüft ob alle Angaben für eine Topologie vorhanden sind und legt eine Leere Topologie an. Hängt eine Spalte für die korrigierte Geometrie und für Fehlermeldungen an die Originaltabelle an. Erzeugt im Topologieschema auch Tabellen für die Abarbeitungsschritte und Statistik. Ist eine gleichnamige Topologie vorhanden wird diese vorher gelöscht.';

-- DROP FUNCTION public.gdi_addToTopo(CHARACTER VARYING, CHARACTER VARYING, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER, INTEGER, INTEGER, BOOLEAN, BOOLEAN);
CREATE OR REPLACE FUNCTION public.gdi_addToTopo(
  topo_name character varying,
  geom_column character varying,
  topo_tolerance double precision,
  area_tolerance double precision,
  polygon_id INTEGER,
  f INTEGER,
  i INTEGER,
  debug boolean
)
  RETURNS INTEGER AS
$BODY$
  DECLARE
    start_time timestamptz;
    delta_time double precision;
    msg text;
    sql text;
    factor Double PRECISION;
  BEGIN
    IF i < 4 THEN
      factor = CASE
        WHEN i = 2 THEN 1.5
        WHEN i = 3 THEN 0.5
        ELSE 1.0
      END;
      msg = FORMAT('%s. try to add geometry of polygon_id: %s to topology.', i, polygon_id);
      sql = '
        UPDATE ' || topo_name || '.topo_geom
        SET ' || geom_column || '_topo = topology.toTopoGeom(' || geom_column || ', ''' || topo_name || ''', 1, ' || topo_tolerance * factor || ')
        WHERE polygon_id = ' || polygon_id || '
      ';
      IF debug THEN RAISE NOTICE 'Try to create TopoGeom with sql: %', sql; END IF;
      PERFORM gdi_logsql('CreateTopo', msg, sql);

      BEGIN
        start_time = clock_timestamp();
        EXECUTE sql;

        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF true THEN RAISE NOTICE '- % ms Duration of toTopoGeom', lpad(round(delta_time)::text, 6, ' '); END IF; 

        start_time = clock_timestamp();
        msg = 'Clean Topo.';
        sql = 'SELECT gdi_CleanPolygonTopo(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ' || area_tolerance || ', ' || polygon_id || ', ' || debug || ')';
        PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF true THEN RAISE NOTICE '- % ms Duration of gdi_CleanPolygonTopo', lpad(round(delta_time)::text, 6, ' '); END IF; 

        BEGIN
          start_time = clock_timestamp();
          sql = 'SELECT gdi_RemoveTopoOverlaps(
            ''' || topo_name || ''',
            ''' || topo_name || ''',
            ''topo_geom'',
            ''polygon_id'',
            ''' || geom_column || ''',
            ''' || geom_column || '_topo''
          )';
          PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
          delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
          IF true THEN RAISE NOTICE '- % ms Duration of gdi_RemoveTopoOverlaps', lpad(round(delta_time)::text, 6, ' '); END IF; 

          start_time = clock_timestamp();
          msg = 'Remove nodes between edges';
          sql = 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
          PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
          delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
          IF true THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'Removing of Overlaps failed: %', SQLERRM;
        END;

      EXCEPTION WHEN OTHERS THEN
        if i = 3 THEN
          -- Error in 3. try of adding the polygon to topology
          RAISE WARNING '%. try of loading polygon_id: % with tolerance % failed: %', i, polygon_id, topo_tolerance * factor, SQLERRM;
          f = f + 1;
          msg = 'Write Error Message.';
          sql = '
            UPDATE ' || topo_name || '.topo_geom
            SET err_msg = ''' || SQLERRM || ' with tolerance' || topo_tolerance * factor || '''
            WHERE polygon_id = ' || polygon_id || '
          ';
          PERFORM gdi_logsql('addToTopo', msg, sql); EXECUTE sql;
        ELSE
          -- give him a next try
          i = i + 1;
          EXECUTE FORMAT('
            SELECT gdi_addToTopo(
              %1$L, %2$L, %3$s, %4$s, %5$s, %6$s, %7$s, %8$L
            )',
            topo_name, geom_column, topo_tolerance, area_tolerance, polygon_id, f, i, debug
          )
          INTO f;
        END IF;
      END;
    END IF;
    RETURN f;
  END;
$BODY$
LANGUAGE plpgsql VOLATILE COST 100;

-- DROP FUNCTION public.gdi_createtopo(character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, double precision, boolean, boolean, character varying, boolean, boolean);
CREATE OR REPLACE FUNCTION public.gdi_createtopo(
    schema_name character varying,
    table_name character varying,
    id_column character varying,
    geom_column character varying,
    expression_column character varying,
    epsg_code integer,
    distance_tolerance double precision,
    angle_toleracne double precision,
    topo_tolerance double precision,
    area_tolerance double precision,
    gap_area_tolerance double precision,
    prepare_topo boolean,
    only_prepare_topo boolean,
    expression character varying,
    debug boolean,
    stop_on_error BOOLEAN
)
  RETURNS INTEGER AS
$BODY$
  DECLARE
    t integer = 0;
    f integer = 0;
    f_before INTEGER;
    sql text;
    polygon RECORD;
    topo_name CHARACTER VARYING = table_name || '_topo';
    start_time timestamptz;
    delta_time double precision;
    expression_where CHARACTER VARYING = '';
    msg text;
    result integer;
  BEGIN
    RAISE NOTICE 'Starte create_topo: %', clock_timestamp();
    IF prepare_topo THEN
      -- Prepare the polygon topology
      IF debug THEN RAISE NOTICE 'Prepare Topology'; END IF;
      EXECUTE FORMAT('
        SELECT gdi_PreparePolygonTopo(
          %1$L,
          %2$L,
          %3$L,
          %4$L,
          %5$L,
          %6$L,
          %7$L,
          %8$s,
          %9$s,
          %10$s,
          %11$s,
          %12$s,
          %13$L
        )',
        topo_name, schema_name, table_name, id_column, geom_column, expression_column, expression, epsg_code, distance_tolerance, angle_toleracne, topo_tolerance, area_tolerance, debug
      );
      delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
      IF true THEN RAISE NOTICE '- % ms Duration of gdi_PreparePolygonTopo', lpad(round(delta_time)::text, 6, ' '); END IF;
    END IF;

    IF expression IS NOT NULL THEN
      expression_where = 'WHERE ' || expression_column || ' ' || expression;
    END IF;

    RAISE NOTICE 'only prepare topo: %', only_prepare_topo;
    IF NOT only_prepare_topo THEN
      -- query polygons
      msg = 'Query prepared objects for topo generation.';
      sql = '
        SELECT
          ' || id_column || ' AS object_id,
          polygon_id AS id
        FROM
          ' || topo_name || '.topo_geom '
        || expression_where || '
        ORDER BY polygon_id
      ';
      IF debug THEN RAISE NOTICE '% with sql: %', msg, sql; END IF;
      PERFORM gdi_logsql('CreateTopo', msg, sql);

      FOR polygon IN EXECUTE sql LOOP
        IF debug THEN RAISE NOTICE 'Create TopGeom for object % polygon %', polygon.object_id, polygon.id; END IF;
        t = t + 1;
        f_before = f;
        EXECUTE FORMAT('
          SELECT gdi_addToTopo(
            %1$L, %2$L, %3$s, %4$s, %5$s, %6$s, %7$s, %8$L
          )',
          topo_name, geom_column, topo_tolerance, area_tolerance, polygon.id, f, 1, debug
        )
        INTO f;
        if f > f_before AND stop_on_error THEN
          EXIT;
        END IF;
      END LOOP;

      BEGIN
        start_time = clock_timestamp();
        msg = 'Close Gaps.';
        sql = 'SELECT gdi_CloseTopoGaps(''' || topo_name || ''', ''' || topo_name || ''', ''topo_geom'', ''' || geom_column || '_topo'', ' || gap_area_tolerance || ')';
        PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF debug THEN RAISE NOTICE '- % ms Duration of gdi_CloseTopoGaps', lpad(round(delta_time)::text, 6, ' '); END IF;

        start_time = clock_timestamp();
        msg = 'Nose Remove between edges.';
        sql = 'SELECT gdi_RemoveNodesBetweenEdges(''' || topo_name || ''')';
        PERFORM gdi_logsql('CreateTopo', msg, sql); EXECUTE sql;
        delta_time = 1000 * (extract(epoch from clock_timestamp()) - extract(epoch from start_time));
        IF true THEN RAISE NOTICE '- % ms Duration of gdi_RemoveNodesBetweenEdges', lpad(round(delta_time)::text, 6, ' '); END IF;

      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Closing of Gaps failed: %', SQLERRM;
      END;

    END IF;
    RAISE NOTICE '% Polygons added to Topology % failed.', t, f;

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der gelöschten Topologieüberlappungen'',
        (SELECT Round(Sum(ST_Area(face_geom))) FROM ' || topo_name || '.removed_overlaps),
        ''m2''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der gefüllten Topologielücken'',
        (SELECT Round(Sum(ST_Area(face_geom))) FROM ' || topo_name || '.filled_gaps),
        ''m2''
      )
    ';

    -- Zurückschreiben der korrigierten Geometrien in die Spalte geom_column_topo_corrected in der Originaltabelle
    RAISE NOTICE 'Rewrite corrected geometry back to the original table: %.% Column: %_topo_corrected', schema_name, table_name , geom_column;
    EXECUTE '
      UPDATE
        ' || schema_name || '.' || table_name || ' AS alt
      SET
        ' || geom_column || '_topo_corrected = neu.geom
      FROM
        (
          SELECT
            id,
            ST_Multi(ST_Union(geom)) AS geom
          FROM
            (
              SELECT ' || id_column || ' AS id, topology.ST_GetFaceGeometry(''' || topo_name || ''', (topology.GetTopoGeomElements(' || geom_column || '_topo))[1]) AS geom FROM ' || topo_name || '.topo_geom
            ) foo
          GROUP BY
            id
        ) neu
      WHERE
        alt.' || id_column || ' = neu.id
    ';

    EXECUTE 'CREATE INDEX ' || table_name || '_' || geom_column || '_topo_corrected_gist ON ' || schema_name || '.' || table_name || ' USING gist(' || geom_column || '_topo_corrected)';

    RAISE NOTICE 'Calculate and log intersections of corrected geometries.';
    EXECUTE '
      INSERT INTO ' || topo_name || '.intersections (step, polygon_a_id, polygon_b_id, the_geom)
      SELECT
        ''nach TopoCorrection'',
        a.gid,
        b.gid,
        ST_Multi(
          ST_CollectionExtract(
            ST_MakeValid(st_intersection(a.the_geom_topo_corrected, b.the_geom_topo_corrected))
            ,3
          )
      )
      FROM
        ' || schema_name || '.' || table_name || ' a JOIN
        ' || schema_name || '.' || table_name || ' b ON (
          a.gid > b.gid AND
          ST_Intersects(a.the_geom_topo_corrected, b.the_geom_topo_corrected) AND
          NOT ST_Touches(a.the_geom_topo_corrected, b.the_geom_topo_corrected)
        )
      ORDER BY
        a.gid, b.gid
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Fläche der Überlappungen korrigierter Geometrien'',
        COALESCE(
          (
            SELECT Round(Sum(ST_Area(the_geom)))
            FROM ' || topo_name || '.intersections
            WHERE step = ''nach TopoCorrection''
          ),
          0
        ),
        ''m2''
      ), (
        ''Gesamtfläche korrigierter Geometrien'', (
          SELECT Round(Sum(ST_Area(' || geom_column || '_topo_corrected)))/10000
          FROM ' || schema_name || '.' || table_name || '
        ),
        ''ha''
      ), (
        ''Anzahl Flächen nach Korrektur'', (SELECT count(*) FROM ' || schema_name || '.' || table_name || '), ''Stück''
      ), (
        ''Anzahl Stützpunkte hinterher'', (
          SELECT Sum(ST_NPoints(' || geom_column || '_topo_corrected))
          FROM ' || schema_name || '.' || table_name || '
        ),
        ''Stück''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz nach - vor Topo-Korrektur'',
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche korrigierter Geometrien'') -
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche nach NoseRemove''),
        ''m2''
      )
    ';


    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz gesamt'',
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche korrigierter Geometrien'') -
        (SELECT round(value * 10000) FROM ' || topo_name || '.statistic WHERE key = ''Gesamtfläche vorher''),
        ''m2''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Flächendifferenz Lücken - Überlappungen'',
        (SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Fläche der gefüllten Topologielücken'') -
        (SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Fläche der gelöschten Topologieüberlappungen''),
        ''m2''
      )
    ';

    EXECUTE '
      INSERT INTO ' || topo_name || '.statistic (key, value, description) VALUES
      (
        ''Absoluter Betrag der Differenz der Flächendifferenz gesamt / Lücken-Überlappungen'',
        ABS ((SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Flächendifferenz gesamt'') -
        (SELECT value FROM ' || topo_name || '.statistic WHERE key = ''Flächendifferenz Lücken - Überlappungen'')),
        ''m2''
      )
    ';

    RAISE NOTICE 'Beende create_topo: %', clock_timestamp();
    RETURN f;
  END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
COMMENT ON FUNCTION public.gdi_createtopo(character varying, character varying, character varying, character varying, character varying, integer, double precision, double precision, double precision, double precision, double precision, boolean, boolean, character varying, boolean, BOOLEAN) IS 'Erzeugt die Topologie <table_name>_topo der Tabelle <table_name> in der temporären Tabelle <table_name>_topo mit einer Toleranz von <tolerance> für alle Geometrie aus Spalte <geom_column>, die der Bedingung <expression> genügen. Ist <prepare_topo> false, wird PreparePolygonTopo nicht ausgeführt. Ist <only_prepare_topo> true wird nur die Topologie vorbereitet. Die Rückgabe ist die Anzahl von Polygonen, die nicht zur Topologie hinzugefügt werden konnte.';

CREATE OR REPLACE FUNCTION public.gdi_cleanPolygon(
  geom geometry,
  epsg_code integer,
  distance_tolerance double precision,
  area_tolerance double precision
)
RETURNS geometry AS
$BODY$
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
$BODY$
  LANGUAGE sql VOLATILE STRICT
  COST 100;