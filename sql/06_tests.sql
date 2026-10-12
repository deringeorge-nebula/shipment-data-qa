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
