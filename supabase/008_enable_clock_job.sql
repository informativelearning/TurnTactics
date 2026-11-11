-- Run after 007 in SQL Editor as the project admin.
-- Enables background processing while no browser is open. Same job name updates rather than duplicates.
create extension if not exists pg_cron;
select cron.schedule('turn-tactics-pacific-clock','* * * * *','select public.tt_clock_all();');
-- Keep only this project's clock-job history for 7 days. Does not delete other jobs' logs.
select cron.schedule('turn-tactics-clock-log-cleanup','17 10 * * *',$$delete from cron.job_run_details where jobid in (select jobid from cron.job where jobname in ('turn-tactics-pacific-clock','turn-tactics-clock-log-cleanup')) and end_time < now()-interval '7 days';$$);
-- Confirm both jobs are active:
select jobname,schedule,active from cron.job where jobname in ('turn-tactics-pacific-clock','turn-tactics-clock-log-cleanup');
