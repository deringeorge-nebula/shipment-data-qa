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
