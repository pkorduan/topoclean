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
  COST 100;