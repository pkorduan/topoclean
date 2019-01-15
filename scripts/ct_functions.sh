#!/bin/bash
logfile="cleantopo.log"

log() {
  if [ -z ${logfile} ] ; then
    echo ${1}
  else
    echo "$(date): ${1}" >> ${logfile}
  fi
}

exec_sql() {
  log "Exec Sql: ${1}"
  result=$(psql -h 172.17.0.8 -U postgres -X -c "${1}" --no-align -t --field-separator ' ' --quiet topo_test)
}