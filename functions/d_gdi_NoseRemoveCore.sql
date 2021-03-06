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

