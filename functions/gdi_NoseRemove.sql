/*
* This function and gdi_NoseRemove is copied from https://trac.osgeo.org/postgis/wiki/UsersWikiExamplesSpikeRemover
* but corrected and extended by distance tolerance so this function not only removes spikes but also small edges
* therewith you can delete long noses.
* Have also a look at this post, related to the topic: https://gis.stackexchange.com/questions/173977/how-to-remove-spikes-in-polygons-with-postgis 
*/
--DROP FUNCTION IF EXISTS public.gdi_NoseRemoveCore(CHARACTER VARYING, INTEGER, geometry, double precision, double precision);
CREATE OR REPLACE FUNCTION public.gdi_NoseRemoveCore(
  topo_name CHARACTER VARYING,
  polygon_id INTEGER,
  geometry,
  angle_tolerance double precision,
  distance_tolerance double precision)
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
  angle_in_point float;
  distance_to_next_point FLOAT;
DECLARE
  debug BOOLEAN = FALSE;
BEGIN
  -- input geometry or rather set as default for the output 
  newgeom := ingeom;

  IF debug THEN RAISE NOTICE 'Start function gdi_NoseRemoveCore'; END IF;
  -- check polygon
  if (select ST_GeometryType(ingeom)) = 'ST_Polygon' then
    IF (SELECT debug) THEN RAISE NOTICE 'ingeom is of type ST_Polygon'; END IF;
    IF (SELECT ST_NumInteriorRings(ingeom)) = 0 then
      IF (SELECT debug) THEN RAISE NOTICE 'num interior ring is 0'; END IF;
      --save the polygon boundary as a line
      lineusp := ST_Boundary(ingeom) as line;
      -- number of tags
      numpoints := ST_NumPoints(lineusp);
      IF (numpoints > 3) THEN
        IF (SELECT debug) THEN RAISE NOTICE 'num points of the line: %', numpoints; END IF;
        -- default value of the loop indicates if the geometry has been changed 
        newb := true;  
        -- globale changevariable 
        changed := false;

        -- loop (to remove several points)
        WHILE newb = true loop
          -- default values
          remove_point := false;
          newb := false;
          point_id := 1;
          numpoints := ST_NumPoints(lineusp) - 1;
          IF (numpoints > 3) THEN
            -- the geometry passes pointwisely until spike has been found and point removed
            WHILE (point_id <= numpoints) AND (remove_point = false) LOOP
              -- the check of the angle at the current point of a spike including the special case, that it is the first point.
                angle_in_point = (
                select
                  abs(
                    pi() -
                    abs(
                      ST_Azimuth(
                        ST_PointN(lineusp, case when point_id = 1 then ST_NumPoints(lineusp) - 1 else point_id - 1 end), 
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
              IF debug THEN RAISE NOTICE 'P: %, d: %, ß: %, a in P % (%): %, a in P % (%): %',
                point_id,
                distance_to_next_point,
                angle_in_point,
                case when point_id = 1 then ST_NumPoints(lineusp) - 1 else point_id - 1 end,
                ST_AsText(ST_PointN(lineusp, case when point_id = 1 then ST_NumPoints(lineusp) - 1 else point_id - 1 end)),
                ST_Azimuth(
                  ST_PointN(lineusp, case when point_id = 1 then ST_NumPoints(lineusp) - 1 else point_id - 1 end), 
                  ST_PointN(lineusp, point_id)
                ),
                point_id,
                ST_AsText(ST_PointN(lineusp, point_id)),
                ST_Azimuth(
                  ST_PointN(lineusp, point_id),
                  ST_PointN(lineusp, point_id + 1)
                );
              END IF;

              IF angle_in_point < angle_tolerance OR distance_to_next_point < distance_tolerance then
                -- remove point
                removed_point_geom = ST_PointN(lineusp, point_id + 1);
                linenew := ST_RemovePoint(lineusp, point_id - 1);

                IF linenew is not null THEN
                  RAISE NOTICE '---> point % removed (%)', point_id, ST_AsText(removed_point_geom);
                  EXECUTE '
                    INSERT INTO ' || topo_name || '.removed_spikes (polygon_id, geom) VALUES
                      (' || polygon_id || ', ''' || removed_point_geom::text || ''')
                  ';
                  lineusp := linenew;
                  remove_point := true;

                  -- if the first point is concerned, the last point must also be changed to close the line again.
                  IF point_id = 1 THEN
                    linenew := ST_SetPoint(lineusp, numpoints - 2, ST_PointN(lineusp, 1));
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
        END LOOP; -- end of loop to remove several points

        --with the change it is tried to change back the new line geometry in a polygon. if this is not possible, the existing geometry is used
        IF changed = true then
          newgeom :=  ST_BuildArea(lineusp) as geom;
          -- errorhandling
          IF newgeom is not null THEN
            raise notice 'new geometry created!';
          ELSE
            newgeom := ingeom;
            raise notice '-------------- area could not be created !!! --------------';
            testgeom := ST_AsText(lineusp);
            raise notice 'geometry %', testgeom;
          END IF; -- newgeom is not null
        END IF; -- geom has been changed
      ELSE
        IF (SELECT debug) THEN RAISE NOTICE 'Break loop due to num points of the line is only %', numpoints; END IF;
      END IF; -- ingeom has more than 3 points
    end if; -- ingeom has 0 interior rings
  end if; -- ingeom is of type ST_Polygon
  -- return value
  RETURN newgeom;
END;
$BODY$
LANGUAGE plpgsql VOLATILE COST 100;
COMMENT ON FUNCTION gdi_NoseRemoveCore(CHARACTER VARYING, INTEGER, geometry, double precision, double precision) IS 'Entfernt schmale Nasen und Kerben in der Umrandung von Polygonen durch abwechslendes Löschen von Punkten mit Abständen < <distance_tolerance> und von Scheitelpunkten mit spitzen Winkeln < <angle_tolerance> in arc';

--DROP FUNCTION IF EXISTS public.gdi_NoseRemove(CHARACTER VARYING, INTEGER, geometry, double precision, double precision);
CREATE OR REPLACE FUNCTION public.gdi_NoseRemove(
  topo_name CHARACTER VARYING,
  polygon_id INTEGER,
  geometry,
  angle double precision,
  tolerance double precision)
RETURNS geometry AS
$BODY$ 
  SELECT ST_MakePolygon(
    (
      --outer ring of polygon
      SELECT ST_ExteriorRing(gdi_NoseRemoveCore($1, $2, geom, $4, $5)) as outer_ring
      FROM ST_DumpRings($3)
      where path[1] = 0 
    ),
    array(
      --all inner rings
      SELECT ST_ExteriorRing(gdi_NoseRemoveCore($1, $2, geom, $4, $5)) as inner_rings
      FROM ST_DumpRings($3)
      WHERE path[1] > 0
    ) 
) as geom
$BODY$
LANGUAGE sql IMMUTABLE COST 100;
COMMENT ON FUNCTION gdi_NoseRemove(CHARACTER VARYING, INTEGER, geometry, double precision, double precision) IS 'Entfernt schmale Nasen und Kerben in Polygongeometrie durch Aufruf von der Funktion gdi_NoseRemoveCore für jeden inneren und äußeren Ring und anschließendes wieder zusammenfügen zu Polygon.';