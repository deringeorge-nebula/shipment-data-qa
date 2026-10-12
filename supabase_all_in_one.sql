DROP SCHEMA IF EXISTS shipqa CASCADE;
CREATE SCHEMA shipqa;
SET search_path TO shipqa;

CREATE TABLE ports (
    locode  text PRIMARY KEY,
    name    text NOT NULL,
    country text NOT NULL,
    lat     double precision NOT NULL,
    lon     double precision NOT NULL
);

INSERT INTO ports VALUES
    ('SGSIN', 'Singapore',      'SG',  1.26, 103.84),
    ('INNSA', 'Nhava Sheva',    'IN', 18.95,  72.95),
    ('INMAA', 'Chennai',        'IN', 13.10,  80.30),
    ('INCOK', 'Kochi',          'IN',  9.97,  76.26),
    ('LKCMB', 'Colombo',        'LK',  6.95,  79.84),
    ('AEJEA', 'Jebel Ali',      'AE', 25.01,  55.06),
    ('CNSHA', 'Shanghai',       'CN', 30.63, 122.07),
    ('MYPKG', 'Port Klang',     'MY',  3.00, 101.39);

CREATE TABLE vessels (
    imo             integer PRIMARY KEY,
    name            text    NOT NULL,
    service_speed_kn numeric NOT NULL
);

INSERT INTO vessels VALUES
    (9000011, 'SYN ARABELLA',  17.5),
    (9000022, 'SYN BRAHMAPUTRA', 16.0),
    (9000033, 'SYN CORAL',     18.5),
    (9000044, 'SYN DELTA',     15.5),
    (9000055, 'SYN EMERALD',   19.0),
    (9000066, 'SYN FALCON',    17.0);

CREATE TABLE milestones (
    event_code text PRIMARY KEY,
    seq        integer NOT NULL UNIQUE,
    at_origin  boolean NOT NULL
);

INSERT INTO milestones VALUES
    ('GATE_IN',    1, true),
    ('LOADED',     2, true),
    ('DEPARTED',   3, true),
    ('ARRIVED',    4, false),
    ('DISCHARGED', 5, false),
    ('GATE_OUT',   6, false);

CREATE TABLE voyages (
    voyage_id   integer PRIMARY KEY,
    imo         integer NOT NULL REFERENCES vessels,
    origin      text    NOT NULL REFERENCES ports,
    destination text    NOT NULL REFERENCES ports,
    atd         timestamptz NOT NULL,
    ata         timestamptz NOT NULL
);

CREATE TABLE shipments (
    shipment_id       integer PRIMARY KEY,
    container_no      text    NOT NULL,
    carrier           text    NOT NULL,
    voyage_id         integer NOT NULL REFERENCES voyages,
    planned_departure timestamptz NOT NULL,
    planned_arrival   timestamptz NOT NULL
);

CREATE TABLE container_events (
    event_id    bigserial PRIMARY KEY,
    shipment_id integer NOT NULL,
    event_code  text    NOT NULL,
    event_time  timestamptz NOT NULL,
    location    text,
    received_at timestamptz NOT NULL
);

CREATE TABLE vessel_positions (
    imo    integer NOT NULL,
    ts     timestamptz NOT NULL,
    lat    double precision NOT NULL,
    lon    double precision NOT NULL,
    sog_kn double precision NOT NULL,
    PRIMARY KEY (imo, ts)
);

CREATE TABLE eta_predictions (
    shipment_id   integer NOT NULL REFERENCES shipments,
    predicted_at  timestamptz NOT NULL,
    predicted_eta timestamptz NOT NULL,
    PRIMARY KEY (shipment_id, predicted_at)
);

CREATE TABLE injected_faults (
    fault_type text NOT NULL,
    row_key    text NOT NULL,
    note       text,
    PRIMARY KEY (fault_type, row_key)
);

CREATE FUNCTION nm(lat1 double precision, lon1 double precision,
                   lat2 double precision, lon2 double precision)
RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
    SELECT 3440.065 * 2 * asin(sqrt(
        power(sin(radians(lat2 - lat1) / 2), 2)
        + cos(radians(lat1)) * cos(radians(lat2))
          * power(sin(radians(lon2 - lon1) / 2), 2)
    ));
$$;

CREATE FUNCTION iso6346_check_digit(prefix10 text)
RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT (sum(
              CASE WHEN c ~ '[0-9]' THEN c::int
                   ELSE (ascii(c) - 55) + (ascii(c) - 56) / 10
              END * power(2, i - 1)::int
           ) % 11) % 10
    FROM unnest(string_to_array(upper(prefix10), NULL)) WITH ORDINALITY AS t(c, i);
$$;

CREATE FUNCTION container_no_is_valid(cno text)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT cno ~ '^[A-Z]{3}[UJZ][0-9]{7}$'
       AND shipqa.iso6346_check_digit(left(cno, 10)) = right(cno, 1)::int;
$$;

TRUNCATE voyages, shipments, container_events, vessel_positions,
         eta_predictions, injected_faults RESTART IDENTITY CASCADE;

CREATE OR REPLACE FUNCTION randn() RETURNS double precision
LANGUAGE sql VOLATILE AS $$
    SELECT sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random());
$$;

CREATE OR REPLACE FUNCTION runif(a double precision, b double precision)
RETURNS double precision
LANGUAGE sql VOLATILE AS $$
    SELECT a + (b - a) * random();
$$;

SELECT setseed(0.42);

DO $$
DECLARE
    v           record;
    cur_port    text;
    next_port   text;
    t_dep       timestamptz;
    t_arr       timestamptz;
    dist        double precision;
    speed       double precision;
    o           record;
    d           record;
    vid         integer := 0;
    sid         integer := 0;
    n_cont      integer;
    t           timestamptz;
    frac        double precision;
    carrier     text;
    serial      text;
    plan_dep    timestamptz;
    t_gate_in   timestamptz;
    t_loaded    timestamptz;
    t_dis       timestamptz;
    t_gate_out  timestamptz;
    transit_h   double precision;
    remain_h    double precision;
    p           double precision;
    season_end  timestamptz := '2026-09-30 00:00+00';
BEGIN
    FOR v IN SELECT * FROM vessels ORDER BY imo LOOP
        SELECT locode INTO cur_port FROM ports ORDER BY random() LIMIT 1;
        t_dep := '2026-01-03 00:00+00'::timestamptz + make_interval(hours => (runif(0, 120))::int);

        LOOP
            SELECT locode INTO next_port FROM ports
             WHERE locode <> cur_port ORDER BY random() LIMIT 1;
            SELECT * INTO o FROM ports WHERE locode = cur_port;
            SELECT * INTO d FROM ports WHERE locode = next_port;

            dist  := nm(o.lat, o.lon, d.lat, d.lon);
            speed := v.service_speed_kn * runif(0.88, 1.02);
            t_arr := date_trunc('minute', t_dep + make_interval(secs => dist / speed * 3600));
            EXIT WHEN t_arr > season_end;

            vid := vid + 1;
            INSERT INTO voyages VALUES (vid, v.imo, cur_port, next_port, t_dep, t_arr);

            t := t_dep;
            WHILE t < t_arr LOOP
                frac := extract(epoch FROM t - t_dep) / extract(epoch FROM t_arr - t_dep);
                INSERT INTO vessel_positions VALUES (
                    v.imo, t,
                    o.lat + frac * (d.lat - o.lat),
                    o.lon + frac * (d.lon - o.lon),
                    greatest(0, speed * (1 + 0.03 * randn())));
                t := t + interval '3 hours';
            END LOOP;
            INSERT INTO vessel_positions VALUES (v.imo, t_arr, d.lat, d.lon, 0);

            n_cont := 1 + floor(random() * 4)::int;
            FOR k IN 1 .. n_cont LOOP
                sid := sid + 1;
                carrier := (ARRAY['CARRIER_A','CARRIER_B','CARRIER_C','CARRIER_D'])[1 + floor(random() * 4)::int];
                serial  := 'SY' || right(carrier, 1) || 'U' || lpad(sid::text, 6, '0');

                plan_dep := t_dep - make_interval(hours => (abs(randn()) * 18)::int);
                INSERT INTO shipments VALUES (
                    sid, serial || iso6346_check_digit(serial), carrier, vid,
                    plan_dep,
                    plan_dep + make_interval(secs => dist / v.service_speed_kn * 3600));

                t_gate_in  := t_dep - make_interval(hours => runif(48, 120)::int);
                t_loaded   := t_dep - make_interval(mins  => runif(120, 840)::int);
                t_dis      := t_arr + make_interval(mins  => runif(240, 1800)::int);
                t_gate_out := t_dis + make_interval(hours => runif(24, 144)::int);

                INSERT INTO container_events (shipment_id, event_code, event_time, location, received_at)
                SELECT sid, e.code, e.ts, e.loc,
                       e.ts + make_interval(mins => runif(5, 360)::int)
                FROM (VALUES ('GATE_IN',    t_gate_in,  cur_port),
                             ('LOADED',     t_loaded,   cur_port),
                             ('DEPARTED',   t_dep,      cur_port),
                             ('ARRIVED',    t_arr,      next_port),
                             ('DISCHARGED', t_dis,      next_port),
                             ('GATE_OUT',   t_gate_out, next_port)) AS e(code, ts, loc);

                transit_h := extract(epoch FROM t_arr - t_dep) / 3600;
                FOREACH p IN ARRAY ARRAY[0.0, 0.25, 0.5, 0.75] LOOP
                    remain_h := transit_h * (1 - p);
                    INSERT INTO eta_predictions VALUES (
                        sid,
                        t_dep + make_interval(secs => p * transit_h * 3600),
                        t_arr + make_interval(secs => (remain_h * (-0.03 + 0.08 * randn())) * 3600));
                END LOOP;
            END LOOP;

            cur_port := next_port;
            t_dep := t_arr + make_interval(hours => runif(24, 60)::int);
        END LOOP;
    END LOOP;
END $$;

CREATE TEMP TABLE pick_s AS
SELECT shipment_id, row_number() OVER (ORDER BY random()) AS r FROM shipments;

CREATE TEMP TABLE pick_v AS
SELECT v.voyage_id, v.imo, row_number() OVER (ORDER BY random()) AS r
FROM voyages v
WHERE (SELECT count(*) FROM vessel_positions p
        WHERE p.imo = v.imo AND p.ts BETWEEN v.atd AND v.ata) >= 20;

WITH t AS (
    SELECT DISTINCT ON (e.shipment_id) e.*
    FROM container_events e JOIN pick_s s USING (shipment_id)
    WHERE s.r BETWEEN 1 AND 12
    ORDER BY e.shipment_id, random()
), ins AS (
    INSERT INTO container_events (shipment_id, event_code, event_time, location, received_at)
    SELECT shipment_id, event_code, event_time, location, received_at + interval '2 hours'
    FROM t RETURNING shipment_id, event_code
)
INSERT INTO injected_faults SELECT 'DUPLICATE_EVENT', shipment_id || ':' || event_code, 'resent by carrier' FROM ins;

WITH t AS (SELECT shipment_id FROM pick_s WHERE r BETWEEN 13 AND 20),
upd AS (
    UPDATE container_events a
       SET event_time = dep.event_time - make_interval(hours => runif(2, 20)::int)
      FROM container_events dep, t
     WHERE a.shipment_id = t.shipment_id AND a.event_code = 'ARRIVED'
       AND dep.shipment_id = t.shipment_id AND dep.event_code = 'DEPARTED'
    RETURNING a.shipment_id
)
INSERT INTO injected_faults SELECT 'OUT_OF_ORDER', shipment_id::text, 'ARRIVED before DEPARTED' FROM upd;

WITH t AS (
    SELECT DISTINCT ON (e.shipment_id) e.event_id, e.shipment_id, e.event_code
    FROM container_events e JOIN pick_s s USING (shipment_id)
    WHERE s.r BETWEEN 21 AND 26
    ORDER BY e.shipment_id, random()
), upd AS (
    UPDATE container_events e
       SET received_at = e.event_time - make_interval(hours => runif(1, 48)::int)
      FROM t WHERE e.event_id = t.event_id
    RETURNING e.shipment_id, e.event_code
)
INSERT INTO injected_faults SELECT 'EVENT_AFTER_RECEIPT', shipment_id || ':' || event_code, 'clock or time-zone error' FROM upd;

WITH del AS (
    DELETE FROM container_events e USING pick_s s
     WHERE e.shipment_id = s.shipment_id AND s.r BETWEEN 27 AND 34
       AND e.event_code = 'DEPARTED'
    RETURNING e.shipment_id
)
INSERT INTO injected_faults SELECT 'MISSING_MILESTONE', shipment_id || ':DEPARTED', 'dropped by feed' FROM del;

WITH t AS (
    SELECT DISTINCT ON (e.shipment_id) e.event_id
    FROM container_events e JOIN pick_s s USING (shipment_id)
    WHERE s.r BETWEEN 35 AND 40
    ORDER BY e.shipment_id, random()
), upd AS (
    UPDATE container_events e
       SET location = left(e.location, 2) || '0' || right(e.location, 2)
      FROM t WHERE e.event_id = t.event_id
    RETURNING e.shipment_id, e.event_code
)
INSERT INTO injected_faults SELECT 'UNKNOWN_LOCATION', shipment_id || ':' || event_code, 'mistyped LOCODE' FROM upd;

WITH upd AS (
    UPDATE shipments sh
       SET container_no = left(container_no, 10) || ((right(container_no, 1)::int + 1) % 10)
      FROM pick_s s
     WHERE sh.shipment_id = s.shipment_id AND s.r BETWEEN 41 AND 45
    RETURNING sh.shipment_id
)
INSERT INTO injected_faults SELECT 'BAD_CONTAINER_NO', shipment_id::text, 'check digit mistyped' FROM upd;

WITH t AS (
    SELECT DISTINCT ON (pv.voyage_id) p.imo, p.ts
    FROM pick_v pv
    JOIN voyages v USING (voyage_id)
    JOIN vessel_positions p ON p.imo = v.imo
     AND p.ts >= v.atd + interval '15 hours' AND p.ts <= v.ata - interval '15 hours'
    WHERE pv.r BETWEEN 1 AND 6
    ORDER BY pv.voyage_id, random()
), upd AS (
    UPDATE vessel_positions p SET lat = p.lat + 4
      FROM t WHERE p.imo = t.imo AND p.ts = t.ts
    RETURNING p.imo, p.ts
)
INSERT INTO injected_faults
SELECT 'POSITION_JUMP', imo || ':' || extract(epoch FROM ts)::bigint, 'GPS glitch' FROM upd;

WITH t AS (SELECT voyage_id FROM pick_v WHERE r BETWEEN 7 AND 9),
upd AS (
    UPDATE vessel_positions p SET sog_kn = p.sog_kn * 0.514444
      FROM voyages v JOIN t USING (voyage_id)
     WHERE p.imo = v.imo AND p.ts BETWEEN v.atd AND v.ata
    RETURNING v.voyage_id
)
INSERT INTO injected_faults SELECT DISTINCT 'SPEED_UNIT_MS', voyage_id::text, 'm/s labelled as knots' FROM upd;

WITH t AS (
    SELECT DISTINCT ON (pv.voyage_id) pv.voyage_id, p.imo, p.ts AS gap_start
    FROM pick_v pv
    JOIN voyages v USING (voyage_id)
    JOIN vessel_positions p ON p.imo = v.imo
     AND p.ts >= v.atd + interval '3 hours' AND p.ts <= v.ata - interval '24 hours'
    WHERE pv.r BETWEEN 10 AND 14
    ORDER BY pv.voyage_id, random()
), del AS (
    DELETE FROM vessel_positions p USING t
     WHERE p.imo = t.imo
       AND p.ts > t.gap_start AND p.ts <= t.gap_start + interval '15 hours'
    RETURNING t.voyage_id, t.gap_start
)
INSERT INTO injected_faults
SELECT DISTINCT 'AIS_GAP', voyage_id || ':' || extract(epoch FROM gap_start)::bigint, '18 h without positions'
FROM del;

DROP TABLE pick_s, pick_v;

SELECT 'voyages' AS table_name, count(*) AS row_count FROM voyages
UNION ALL SELECT 'shipments',        count(*) FROM shipments
UNION ALL SELECT 'container_events', count(*) FROM container_events
UNION ALL SELECT 'vessel_positions', count(*) FROM vessel_positions
UNION ALL SELECT 'eta_predictions',  count(*) FROM eta_predictions
UNION ALL SELECT 'injected_faults',  count(*) FROM injected_faults;

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

CREATE OR REPLACE VIEW qa_match AS
SELECT coalesce(f.check_name, i.fault_type) AS check_name,
       coalesce(f.row_key, i.row_key)       AS row_key,
       CASE WHEN f.row_key IS NOT NULL AND i.row_key IS NOT NULL THEN 'true positive'
            WHEN i.row_key IS NULL THEN 'false positive'
            ELSE 'false negative' END        AS outcome,
       f.detail
FROM qa_findings f
FULL JOIN injected_faults i
       ON i.fault_type = f.check_name AND i.row_key = f.row_key;

CREATE OR REPLACE VIEW qa_scorecard AS
SELECT check_name,
       count(*) FILTER (WHERE outcome <> 'false positive') AS planted,
       count(*) FILTER (WHERE outcome = 'true positive')   AS caught,
       count(*) FILTER (WHERE outcome = 'false negative')  AS missed,
       count(*) FILTER (WHERE outcome = 'false positive')  AS false_alarms,
       round(100.0 * count(*) FILTER (WHERE outcome = 'true positive')
             / nullif(count(*) FILTER (WHERE outcome <> 'false positive'), 0), 1) AS recall_pct,
       round(100.0 * count(*) FILTER (WHERE outcome = 'true positive')
             / nullif(count(*) FILTER (WHERE outcome <> 'false negative'), 0), 1) AS precision_pct
FROM qa_match
GROUP BY check_name
ORDER BY check_name;

SELECT * FROM qa_scorecard;

CREATE TEMP TABLE IF NOT EXISTS test_results (test text, result text);
TRUNCATE test_results;

DO $$
DECLARE
    n_before int;
    n_after  int;
    r        record;
BEGIN
    IF shipqa.iso6346_check_digit('CSQU305438') <> 3 THEN
        RAISE EXCEPTION 'FAIL iso6346: CSQU305438 should give 3';
    END IF;
    IF shipqa.container_no_is_valid('CSQU3054384') THEN
        RAISE EXCEPTION 'FAIL iso6346: a wrong check digit was accepted';
    END IF;
    INSERT INTO test_results VALUES ('ISO 6346 check digit, textbook example', 'PASS');

    IF abs(shipqa.nm(0, 0, 1, 0) - 60.04) > 0.06 THEN
        RAISE EXCEPTION 'FAIL nm: 1 degree of latitude gave % nm', shipqa.nm(0, 0, 1, 0);
    END IF;
    IF shipqa.nm(10, 80, 10, 80) <> 0 THEN
        RAISE EXCEPTION 'FAIL nm: zero distance is not zero';
    END IF;
    INSERT INTO test_results VALUES ('Great-circle distance, 1 degree = 60 nm', 'PASS');

    FOR r IN SELECT * FROM shipqa.qa_scorecard LOOP
        IF r.missed > 0 OR r.false_alarms > 0 THEN
            RAISE EXCEPTION 'FAIL scorecard %: % missed, % false alarms',
                r.check_name, r.missed, r.false_alarms;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM shipqa.qa_scorecard) <> 9 THEN
        RAISE EXCEPTION 'FAIL scorecard: expected 9 checks';
    END IF;
    INSERT INTO test_results VALUES ('All planted faults caught, no false alarms', 'PASS');

    IF EXISTS (SELECT 1 FROM shipqa.clean_shipments c
               JOIN shipqa.injected_faults f
                 ON f.fault_type IN ('DUPLICATE_EVENT','OUT_OF_ORDER','EVENT_AFTER_RECEIPT',
                                     'MISSING_MILESTONE','UNKNOWN_LOCATION','BAD_CONTAINER_NO')
                AND split_part(f.row_key, ':', 1)::int = c.shipment_id) THEN
        RAISE EXCEPTION 'FAIL clean_shipments contains a faulty shipment';
    END IF;
    INSERT INTO test_results VALUES ('Analysis set excludes every faulty shipment', 'PASS');

    BEGIN
        SELECT count(*) INTO n_before FROM shipqa.chk_duplicate_event;
        INSERT INTO shipqa.container_events (shipment_id, event_code, event_time, location, received_at)
        SELECT shipment_id, event_code, event_time, location, received_at
        FROM shipqa.container_events
        WHERE shipment_id = (SELECT min(shipment_id) FROM shipqa.clean_shipments)
          AND event_code = 'GATE_OUT';
        SELECT count(*) INTO n_after FROM shipqa.chk_duplicate_event;
        IF n_after <> n_before + 1 THEN
            RAISE EXCEPTION 'FAIL mutation DUPLICATE_EVENT: % -> %', n_before, n_after;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'TEST1';
    EXCEPTION WHEN SQLSTATE 'TEST1' THEN NULL;
    END;

    BEGIN
        SELECT count(*) INTO n_before FROM shipqa.chk_unknown_location;
        UPDATE shipqa.container_events SET location = 'XXXXX'
         WHERE event_id = (SELECT min(event_id) FROM shipqa.container_events
                           WHERE shipment_id IN (SELECT shipment_id FROM shipqa.clean_shipments));
        SELECT count(*) INTO n_after FROM shipqa.chk_unknown_location;
        IF n_after <> n_before + 1 THEN
            RAISE EXCEPTION 'FAIL mutation UNKNOWN_LOCATION: % -> %', n_before, n_after;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'TEST1';
    EXCEPTION WHEN SQLSTATE 'TEST1' THEN NULL;
    END;

    BEGIN
        SELECT count(*) INTO n_before FROM shipqa.chk_out_of_order;
        UPDATE shipqa.container_events SET event_time = event_time - interval '30 days'
         WHERE shipment_id = (SELECT min(shipment_id) FROM shipqa.clean_shipments)
           AND event_code = 'DISCHARGED';
        SELECT count(*) INTO n_after FROM shipqa.chk_out_of_order;
        IF n_after <> n_before + 1 THEN
            RAISE EXCEPTION 'FAIL mutation OUT_OF_ORDER: % -> %', n_before, n_after;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'TEST1';
    EXCEPTION WHEN SQLSTATE 'TEST1' THEN NULL;
    END;

    BEGIN
        SELECT count(*) INTO n_before FROM shipqa.chk_bad_container_no;
        UPDATE shipqa.shipments
           SET container_no = left(container_no, 10) || ((right(container_no, 1)::int + 5) % 10)
         WHERE shipment_id = (SELECT min(shipment_id) FROM shipqa.clean_shipments);
        SELECT count(*) INTO n_after FROM shipqa.chk_bad_container_no;
        IF n_after <> n_before + 1 THEN
            RAISE EXCEPTION 'FAIL mutation BAD_CONTAINER_NO: % -> %', n_before, n_after;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'TEST1';
    EXCEPTION WHEN SQLSTATE 'TEST1' THEN NULL;
    END;

    BEGIN
        SELECT count(*) INTO n_before FROM shipqa.chk_position_jump;
        UPDATE shipqa.vessel_positions p SET lat = p.lat - 5
          FROM (SELECT vp.imo, vp.ts FROM shipqa.voyage_positions vp
                WHERE vp.voyage_id = (
                    SELECT voyage_id FROM shipqa.voyage_positions
                    GROUP BY voyage_id
                    HAVING count(*) >= 20
                       AND max(implied_kn) < 35
                       AND max(next_ts - ts) <= interval '6 hours'
                    ORDER BY voyage_id LIMIT 1)
                ORDER BY vp.ts OFFSET 9 LIMIT 1) t
         WHERE p.imo = t.imo AND p.ts = t.ts;
        SELECT count(*) INTO n_after FROM shipqa.chk_position_jump;
        IF n_after <> n_before + 1 THEN
            RAISE EXCEPTION 'FAIL mutation POSITION_JUMP: % -> %', n_before, n_after;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'TEST1';
    EXCEPTION WHEN SQLSTATE 'TEST1' THEN NULL;
    END;

    INSERT INTO test_results VALUES ('Mutation tests: 5 new faults, each caught once', 'PASS');

    FOR r IN SELECT * FROM shipqa.qa_scorecard LOOP
        IF r.missed > 0 OR r.false_alarms > 0 THEN
            RAISE EXCEPTION 'FAIL rollback: a mutation leaked into %', r.check_name;
        END IF;
    END LOOP;
    INSERT INTO test_results VALUES ('Mutations rolled back cleanly', 'PASS');
END $$;

SELECT * FROM test_results;
