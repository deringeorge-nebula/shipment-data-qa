SET search_path TO shipqa;

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
