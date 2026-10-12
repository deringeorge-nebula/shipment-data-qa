SET search_path TO shipqa;

CREATE OR REPLACE VIEW chk_duplicate_event AS
SELECT 'DUPLICATE_EVENT'::text AS check_name,
       shipment_id || ':' || event_code AS row_key,
       format('%s copies of %s at %s', count(*), event_code, min(event_time)) AS detail
FROM container_events
GROUP BY shipment_id, event_code, event_time
HAVING count(*) > 1;

CREATE OR REPLACE VIEW chk_out_of_order AS
WITH ordered AS (
    SELECT e.shipment_id, e.event_code, e.event_time, m.seq,
           lag(e.event_code) OVER w AS prev_code,
           lag(e.event_time) OVER w AS prev_time
    FROM container_events e
    JOIN milestones m USING (event_code)
    WINDOW w AS (PARTITION BY e.shipment_id ORDER BY m.seq, e.event_time)
)
SELECT 'OUT_OF_ORDER'::text AS check_name,
       shipment_id::text AS row_key,
       string_agg(format('%s (%s) is earlier than %s (%s)',
                         event_code, event_time, prev_code, prev_time), '; ') AS detail
FROM ordered
WHERE event_time < prev_time
GROUP BY shipment_id;

CREATE OR REPLACE VIEW chk_event_after_receipt AS
SELECT 'EVENT_AFTER_RECEIPT'::text AS check_name,
       shipment_id || ':' || event_code AS row_key,
       format('event %s, received %s', event_time, received_at) AS detail
FROM container_events
WHERE event_time > received_at + interval '5 minutes';

CREATE OR REPLACE VIEW chk_missing_milestone AS
WITH reached AS (
    SELECT e.shipment_id, max(m.seq) AS max_seq
    FROM container_events e JOIN milestones m USING (event_code)
    GROUP BY e.shipment_id
)
SELECT 'MISSING_MILESTONE'::text AS check_name,
       r.shipment_id || ':' || m.event_code AS row_key,
       format('no %s, but milestone %s was reached', m.event_code, r.max_seq) AS detail
FROM reached r
JOIN milestones m ON m.seq < r.max_seq
WHERE NOT EXISTS (SELECT 1 FROM container_events e
                  WHERE e.shipment_id = r.shipment_id AND e.event_code = m.event_code);

CREATE OR REPLACE VIEW chk_unknown_location AS
SELECT 'UNKNOWN_LOCATION'::text AS check_name,
       e.shipment_id || ':' || e.event_code AS row_key,
       format('location %L is not in ports', e.location) AS detail
FROM container_events e
LEFT JOIN ports p ON p.locode = e.location
WHERE p.locode IS NULL;

CREATE OR REPLACE VIEW chk_bad_container_no AS
SELECT 'BAD_CONTAINER_NO'::text AS check_name,
       shipment_id::text AS row_key,
       format('%s: check digit should be %s', container_no,
              iso6346_check_digit(left(container_no, 10))) AS detail
FROM shipments
WHERE NOT container_no_is_valid(container_no);

CREATE OR REPLACE VIEW position_speeds AS
SELECT p.*,
       nm(lag(lat) OVER w, lag(lon) OVER w, lat, lon)
         / nullif(extract(epoch FROM ts - lag(ts) OVER w) / 3600, 0) AS speed_in_kn,
       nm(lat, lon, lead(lat) OVER w, lead(lon) OVER w)
         / nullif(extract(epoch FROM lead(ts) OVER w - ts) / 3600, 0) AS speed_out_kn
FROM vessel_positions p
WINDOW w AS (PARTITION BY imo ORDER BY ts);

CREATE OR REPLACE VIEW voyage_positions AS
SELECT v.voyage_id, p.imo, p.ts, p.lat, p.lon, p.sog_kn,
       nm(lag(p.lat) OVER w, lag(p.lon) OVER w, p.lat, p.lon)
         / nullif(extract(epoch FROM p.ts - lag(p.ts) OVER w) / 3600, 0) AS implied_kn,
       lead(p.ts) OVER w AS next_ts,
       p.ts = v.ata AS is_arrival
FROM voyages v
JOIN vessel_positions p ON p.imo = v.imo AND p.ts BETWEEN v.atd AND v.ata
WINDOW w AS (PARTITION BY v.voyage_id ORDER BY p.ts);

CREATE OR REPLACE VIEW chk_position_jump AS
SELECT 'POSITION_JUMP'::text AS check_name,
       imo || ':' || extract(epoch FROM ts)::bigint AS row_key,
       format('imo %s at %s: %s kn in, %s kn out', imo, ts,
              round(speed_in_kn::numeric, 1), round(speed_out_kn::numeric, 1)) AS detail
FROM position_speeds
WHERE speed_in_kn > 35 AND speed_out_kn > 35;

CREATE OR REPLACE VIEW chk_speed_unit AS
WITH per_voyage AS (
    SELECT voyage_id,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY sog_kn)
               FILTER (WHERE NOT is_arrival) AS median_reported,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY implied_kn) AS median_implied
    FROM voyage_positions
    GROUP BY voyage_id
)
SELECT 'SPEED_UNIT_MS'::text AS check_name,
       voyage_id::text AS row_key,
       format('reported %s kn vs implied %s kn (ratio %s)',
              round(median_reported::numeric, 1), round(median_implied::numeric, 1),
              round((median_reported / median_implied)::numeric, 3)) AS detail
FROM per_voyage
WHERE median_reported / nullif(median_implied, 0) BETWEEN 0.40 AND 0.65;

CREATE OR REPLACE VIEW chk_ais_gap AS
SELECT 'AIS_GAP'::text AS check_name,
       voyage_id || ':' || extract(epoch FROM ts)::bigint AS row_key,
       format('voyage %s: no position from %s to %s (%s)', voyage_id, ts, next_ts, next_ts - ts) AS detail
FROM voyage_positions
WHERE next_ts - ts > interval '6 hours';

CREATE OR REPLACE VIEW qa_findings AS
          SELECT * FROM chk_duplicate_event
UNION ALL SELECT * FROM chk_out_of_order
UNION ALL SELECT * FROM chk_event_after_receipt
UNION ALL SELECT * FROM chk_missing_milestone
UNION ALL SELECT * FROM chk_unknown_location
UNION ALL SELECT * FROM chk_bad_container_no
UNION ALL SELECT * FROM chk_position_jump
UNION ALL SELECT * FROM chk_speed_unit
UNION ALL SELECT * FROM chk_ais_gap;

CREATE OR REPLACE VIEW qa_summary AS
SELECT check_name, count(*) AS findings
FROM qa_findings
GROUP BY check_name
ORDER BY check_name;

CREATE OR REPLACE VIEW clean_shipments AS
SELECT s.*
FROM shipments s
WHERE NOT EXISTS (
    SELECT 1 FROM qa_findings f
    WHERE f.check_name IN ('DUPLICATE_EVENT', 'OUT_OF_ORDER', 'EVENT_AFTER_RECEIPT',
                           'MISSING_MILESTONE', 'UNKNOWN_LOCATION', 'BAD_CONTAINER_NO')
      AND split_part(f.row_key, ':', 1)::int = s.shipment_id
);

SELECT * FROM qa_summary;
