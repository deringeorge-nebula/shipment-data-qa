SET search_path TO shipqa;

WITH m AS (
    SELECT s.shipment_id, s.carrier, s.planned_departure, s.planned_arrival,
           max(e.event_time) FILTER (WHERE e.event_code = 'DEPARTED') AS atd,
           max(e.event_time) FILTER (WHERE e.event_code = 'ARRIVED')  AS ata
    FROM clean_shipments s
    JOIN container_events e USING (shipment_id)
    GROUP BY s.shipment_id, s.carrier, s.planned_departure, s.planned_arrival
)
SELECT carrier,
       count(*) AS shipments,
       round(avg(extract(epoch FROM atd - planned_departure) / 3600)::numeric, 1) AS avg_departure_delay_h,
       round(avg(extract(epoch FROM ata - planned_arrival) / 3600)::numeric, 1)   AS avg_arrival_delay_h,
       round(100.0 * avg((ata - planned_arrival > interval '24 hours')::int), 1) AS pct_arriving_over_1_day_late
FROM m
GROUP BY carrier
ORDER BY carrier;

WITH a AS (
    SELECT shipment_id, event_time AS ata
    FROM container_events
    WHERE event_code = 'ARRIVED'
      AND shipment_id IN (SELECT shipment_id FROM clean_shipments)
), stage AS (
    SELECT p.shipment_id, p.predicted_eta, a.ata,
           row_number() OVER (PARTITION BY p.shipment_id ORDER BY p.predicted_at) AS n
    FROM eta_predictions p JOIN a USING (shipment_id)
)
SELECT CASE n WHEN 1 THEN 'at departure' WHEN 2 THEN '25% of voyage'
              WHEN 3 THEN '50% of voyage' ELSE '75% of voyage' END AS predicted_when,
       count(*) AS predictions,
       round(avg(extract(epoch FROM predicted_eta - ata) / 3600)::numeric, 2)      AS mean_error_h,
       round(avg(abs(extract(epoch FROM predicted_eta - ata)) / 3600)::numeric, 2) AS mean_abs_error_h,
       round((percentile_cont(0.9) WITHIN GROUP
             (ORDER BY abs(extract(epoch FROM predicted_eta - ata)) / 3600))::numeric, 2) AS p90_abs_error_h
FROM stage
GROUP BY n
ORDER BY n;

SELECT v.origin || ' -> ' || v.destination AS route,
       count(*) AS voyages,
       round(avg(extract(epoch FROM v.ata - v.atd) / 3600)::numeric, 1)    AS avg_transit_h,
       round(stddev(extract(epoch FROM v.ata - v.atd) / 3600)::numeric, 1) AS sd_transit_h
FROM voyages v
GROUP BY v.origin, v.destination
HAVING count(*) >= 4
ORDER BY avg_transit_h DESC
LIMIT 10;

WITH t AS (
    SELECT e.shipment_id,
           max(e.location)   FILTER (WHERE e.event_code = 'GATE_IN')   AS origin,
           max(e.location)   FILTER (WHERE e.event_code = 'GATE_OUT')  AS destination,
           max(e.event_time) FILTER (WHERE e.event_code = 'GATE_IN')    AS gate_in,
           max(e.event_time) FILTER (WHERE e.event_code = 'LOADED')     AS loaded,
           max(e.event_time) FILTER (WHERE e.event_code = 'DISCHARGED') AS discharged,
           max(e.event_time) FILTER (WHERE e.event_code = 'GATE_OUT')   AS gate_out
    FROM container_events e
    WHERE e.shipment_id IN (SELECT shipment_id FROM clean_shipments)
    GROUP BY e.shipment_id
), export AS (
    SELECT origin AS locode, avg(extract(epoch FROM loaded - gate_in) / 86400) AS days
    FROM t GROUP BY origin
), import AS (
    SELECT destination AS locode, avg(extract(epoch FROM gate_out - discharged) / 86400) AS days
    FROM t GROUP BY destination
)
SELECT p.locode, p.name,
       round(x.days::numeric, 2) AS avg_export_dwell_days,
       round(i.days::numeric, 2) AS avg_import_dwell_days
FROM ports p
LEFT JOIN export x USING (locode)
LEFT JOIN import i USING (locode)
ORDER BY p.locode;

WITH lat AS (
    SELECT s.carrier, extract(epoch FROM e.received_at - e.event_time) / 3600 AS latency_h
    FROM container_events e JOIN shipments s USING (shipment_id)
    WHERE e.received_at >= e.event_time
), bad AS (
    SELECT s.carrier, count(*) AS findings
    FROM qa_findings f
    JOIN shipments s ON s.shipment_id = split_part(f.row_key, ':', 1)::int
    WHERE f.check_name IN ('DUPLICATE_EVENT', 'OUT_OF_ORDER', 'EVENT_AFTER_RECEIPT',
                           'MISSING_MILESTONE', 'UNKNOWN_LOCATION', 'BAD_CONTAINER_NO')
    GROUP BY s.carrier
)
SELECT l.carrier,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY l.latency_h))::numeric, 2) AS median_latency_h,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY l.latency_h))::numeric, 2) AS p95_latency_h,
       round(100.0 * coalesce(max(b.findings), 0)
             / (SELECT count(*) FROM shipments s WHERE s.carrier = l.carrier), 1) AS findings_per_100_shipments
FROM lat l
LEFT JOIN bad b USING (carrier)
GROUP BY l.carrier
ORDER BY l.carrier;
