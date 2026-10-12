SET search_path TO shipqa;

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
