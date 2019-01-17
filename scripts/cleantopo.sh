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
gap_area_tolerance=${11}
prepare_topo=${12}
only_prepare_topo=${13}
expression="${14}"
debug=${15}
stop_on_error=${16}
pid=$$

usage() {
  echo "Die in createTopo zur Verfügung stehenden Parameter"
  echo "schema_name Name des Schemas in dem die Datentabelle liegt."
  echo "table_name Name der Tabelle in dem die Daten liegen."
  echo "id_column Name der Spalte in der die eindeutige Nummerierung der Polygone ist."
  echo "geom_column Name der Spalte in der die Geometrie ist."
  echo "expression_column Name der Spalte über die gefiltert werden soll. Muss man nur angeben, wenn man auch ein expression angibt, sonst NULL"
  echo "epsg_code SRS die die korrigierte Geometrie haben soll. Sollte Metrisch sein, wenn die Toleranzen in Metern angegeben werden"
  echo "distance_tolerance Maximaler Abstand zwischen benachbarten Punkten in Linien der Polygone"
  echo "angle_toleracne Maximaler Winkel zwischen 3 benachbarten Punkten in Linien von Polygonen"
  echo "topo_tolerance Toleranz für das Erzeugen der Topology"
  echo "area_tolerance Toleranz für das Löschen von inneren Ringen. Ringe mit Flächen kleiner der Toleranz werden gelöscht."
  echo "gap_area_tolerance Toleranz für das Schließen von Lücken zwischen schon berechneten Flächen. Fläche, die kleiner ist als das kleinste Teilpolygon, aber größer als die Lücken zwischen Polygonen."
  echo "prepare_topo Soll die Geometrie vorbereitet werden. False wenn die Geometrie schon gerechnet wurde, z.B. um die Topologie mehrmals nacheinander Rechnen zu können bei Parameter stop_on_error."
  echo "only_prepare_topo True wenn nur die Geometrie vorbereitet und die Topologie nicht berechnet werden soll."
  echo "expression Ausdruck über den der Datensatz gefiltert werden soll. Nur die passenden Polygone werden dann bereinigt."
  echo "debug boolean True wenn Debug-Meldungen als Notice erzeugt werden sollen."
  echo "stop_on_error True wenn das Script bei einem Fehler stoppen soll."
}

next_id() {
  exec_sql "SELECT DISTINCT id, expression FROM ${table_name}_topo.next WHERE pid = ${pid} ORDER BY id LIMIT 1"
  if [ -z ${result} ]; then
    log "Nexttab is leer"
    exec_sql "SELECT ${id_column} FROM ${schema_name}.${table_name} WHERE ${expression} AND ${geom_column}_topo_corrected IS NULL AND ${geom_column}_msg IS NULL ORDER BY ${id_column} LIMIT 1"
  fi
  id=${result}
}

if [ $# -lt 16 ] ; then
  echo "Es müssen 16 Parameter angegeben werden."
  usage
  exit
fi

log "----------------------------------------------------------------" > $logfile
exec_sql "SELECT 1 FROM information_schema.tables WHERE table_schema = '${schema_name}' AND table_name = '${table_name}'"

if [ "${prepare_topo}" == "true" ] ; then
  log "Schema und Tabellen erstellen auch wenn schon vorhanden."
  result=""
fi

if [ -z "${result}" ]; then
  log "Table ${table_name}_topo.topo_geom existiert nicht."
  exec_sql "SELECT gdi_prepareTopo('${2}_topo', '$1', '$2', '$3', '$4', '$5', '${14}', $6, $7, $8, $9, ${10}, '${15}')"
else
  log "Topology ${table_name}_topo existiert bereits."
fi

if [ "${only_prepare_topo}" == "true" ] ; then
  log "Nur Schema und Tabellen erstellen."
else
  next_id
  until [ -z ${id} ]; do
    ./ct_addpolytotopo.sh $1 $2 $3 $4 $5 $6 $7 $8 $9 ${10} ${11} ${12} ${13} "${14}" ${15} ${16} ${id}
    next_id
  done
fi

log "fertig!"
