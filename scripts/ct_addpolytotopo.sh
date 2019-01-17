#!/bin/bash
source ct_functions.sh
schema_name=$1
table_name=$2
id_column=$3
geom_column=$4
expression_column=$5
epsg_code=$6
distance_tolerance=$7
angle_tolerance=$8
topo_tolerance=$9
area_tolerance=${10}
gap_area_tolerance=${11}
prepare_topo=${12}
only_prepare_topo=${13}
expression="${14}"
debug=${15}
stop_on_error=${16}
id=${17}
# pid des Elternprozesses setzen
pid=$PPID

t=0
f=0
f_before=""
sql=""
topo_name="${table_name}_topo";
start_time=`date`
delta_time=0
expression_where=""
msg=""
result=0

log "Add Polygon ${id_column}: ${id} to Topology ${table_name}_topo."

exec_sql "INSERT INTO ${table_name}_topo.topo_geom (${id_column}, ${geom_column})
SELECT ${id_column}, gdi_cleanpolygon(${geom_column}, ${epsg_code}, ${distance_tolerance}, ${area_tolerance}) FROM ${schema_name}.${table_name} WHERE ${id_column} = ${id}"

exec_sql "UPDATE ${table_name}_topo.topo_geom SET ${geom_column} = gdi_filterrings(gdi_noseremove('${table_name}_topo', polygon_id, the_geom, ${angle_tolerance}, ${distance_tolerance}, false), ${area_tolerance}) WHERE ${id_column} = ${id}"

exec_sql "SELECT gdi_addtotopo('${table_name}_topo', '${geom_column}', ${topo_tolerance}, ${area_tolerance}, polygon_id, 0, 1, false) FROM ${table_name}_topo.topo_geom WHERE ${id_column} = ${id}"

log "Entferne ${id} aus next Tabelle."
exec_sql "DELETE FROM ${table_name}_topo.next WHERE id = '${id}' AND pid = ${pid}"

exec_sql "SELECT string_agg(err_msg, ', ') FROM ${table_name}_topo.topo_geom WHERE ${id_column} = ${id} AND err_msg != ''"

if [ -n "${result}" ] ; then
  log "Polygon mit ${id_column}: ${id} hat Fehler verursacht. Schreibe Fehlermeldung in Originaltabelle."
  exec_sql "UPDATE ${schema_name}.${table_name} SET ${geom_column}_msg = '${result}' WHERE ${id_column} = ${id}"
else
  exec_sql "SELECT gdi_CloseTopoGaps('${table_name}_topo', '${table_name}_topo', 'topo_geom', '${geom_column}_topo', ${gap_area_tolerance})"
  exec_sql "SELECT gdi_RemoveNodesBetweenEdges('${table_name}_topo')"

  log "Polygon mit ${id_column}: ${id} erfolgreich zur Topologie hinzugefügt."
  exec_sql "UPDATE ${schema_name}.${table_name} SET ${geom_column}_msg = 'ok' WHERE ${id_column} = ${id}"

  comment="
    UPDATE
      ${schema_name}.${table_name} AS alt
    SET
      ${geom_column}_topo_corrected = neu.geom
    FROM
      (
        SELECT
          id,
          ST_Multi(ST_Union(geom)) AS geom
        FROM
          (
            SELECT ${id_column} AS id, topology.ST_GetFaceGeometry('${table_name}_topo', (topology.GetTopoGeomElements(${geom_column}_topo))[1]) AS geom
            FROM ${table_name}_topo.topo_geom WHERE ${id_column} = ${id}
          ) foo
        GROUP BY
          id
      ) neu
    WHERE
      alt.${id_column} = neu.id
  "

  log "Schreibe Nachbarn von Polygon ${id} in next Tabelle"
  exec_sql "
    INSERT INTO ${table_name}_topo.next (id, pid)
    SELECT
      n.gid,
      ${pid}
    FROM
      (SELECT * FROM ${schema_name}.${table_name} WHERE ${expression}) n JOIN
      ${schema_name}.${table_name} t ON ST_DWithin(ST_Transform(t.${geom_column}, ${epsg_code}), ST_Transform(n.${geom_column}, ${epsg_code}), 10)
    WHERE
      n.${id_column} != t.${id_column} AND
      n.${geom_column}_msg IS NULL AND
      t.${id_column} = ${id}
    ORDER BY ST_DWithin(ST_Transform(t.${geom_column}, ${epsg_code}), ST_Transform(n.${geom_column}, ${epsg_code}), 10)
  "
fi