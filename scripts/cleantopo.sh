#!/bin/bash
source ct_functions.sh
schema_name=$1
table_name=$2
id_column=$3
geom_column=$4
expression_column=$5
epsg_code=$6
distance_tolerance=$7
angle_toleracne=$8
topo_tolerance=$9
area_tolerance=${10}
prepare_topo=${11}
only_prepare_topo=${12}
expression="${13}"
debug=${14}
stop_on_error=${15}

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

next_id() {
  exec_sql "SELECT DISTINCT id FROM ${table_name}_topo.next ORDER BY id LIMIT 1"
  if [ -z ${result} ]; then
    log "Nexttab is leer"
    exec_sql "SELECT ${id_column} FROM ${schema_name}.${table_name} WHERE ${expression} AND ${geom_column}_topo_corrected IS NULL AND ${geom_column}_msg IS NULL ORDER BY ${id_column} LIMIT 1"
  fi
  id=${result}
}

log "----------------------------------------------------------------" > $logfile
exec_sql "SELECT 1 FROM information_schema.tables WHERE table_schema = '${schema_name}' AND table_name = '${table_name}'"

if [ "${prepare_topo}" == "true" ] ; then
  log "Schema und Tabellen erstellen auch wenn schon vorhanden."
  result=""
fi

if [ -z "${result}" ]; then
  log "Table ${table_name}_topo.topo_geom existiert nicht."
  exec_sql "SELECT gdi_prepareTopo('${2}_topo', '$1', '$2', '$3', '$4', '$5', '${13}', $6, $7, $8, $9, ${10}, '${14}')"
else
  log "Topology ${table_name}_topo existiert bereits."
fi

if [ "${only_prepare_topo}" == "true" ] ; then
  log "Nur Schema und Tabellen erstellen."
else
  next_id
  until [ -z ${id} ]; do
    ./ct_addpolytotopo.sh $1 $2 $3 $4 $5 $6 $7 $8 $9 ${10} ${11} ${12} "${13}" ${14} ${15} ${id}
    next_id
  done
fi

log "fertig!"
