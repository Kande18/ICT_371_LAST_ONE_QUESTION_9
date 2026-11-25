-- =====================================================================
-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q9_Farmer_Cooperative_Maize_Deliveries.sql
-- Rates per kg: grade A = K5, grade B = K4, grade C = K3.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
--     unit_rate and total_value are NOT NULL but are always filled by the BEFORE
--     trigger (BEFORE triggers run before NOT NULL / CHECK constraints are tested).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

CREATE TABLE farmers (
    farmer_id      SERIAL       PRIMARY KEY,
    farmer_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   SERIAL        PRIMARY KEY,
    farmer_id     INTEGER       NOT NULL REFERENCES farmers (farmer_id),
    grade         CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(10,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL,
    delivered_on  DATE          NOT NULL,
    is_paid       BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date  DATE          PRIMARY KEY,
    total_weight   NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_value    NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Joseph Mwanza'),
    ('F002', 'Agnes Zulu'),
    ('F003', 'Patrick Sinkala');

-- ---------------------------------------------------------------------
-- (b) Function fn_maize_rate
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    IF    p_grade = 'A' THEN RETURN 5.00;
    ELSIF p_grade = 'B' THEN RETURN 4.00;
    ELSIF p_grade = 'C' THEN RETURN 3.00;
    ELSE
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger (installed before any delivery is loaded)
--     Applies to procedure AND direct SQL, so pricing is always consistent.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);          -- raises on bad grade
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_price_delivery ON deliveries;
CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- ---------------------------------------------------------------------
-- (c) Procedure pr_receive_delivery
--     Inserts only the basic fields; the trigger supplies unit_rate/total_value.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: % (use A, B or C)', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ---------------------------------------------------------------------
-- (e) View: v_farmer_amount_due (LEFT JOIN so farmers with nothing unpaid show 0)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- ---------------------------------------------------------------------
-- (f) Composite index: a farmer's deliveries between two dates
--     farmer_id (equality) first, delivered_on (range) second.
-- ---------------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

-- ---------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_purchases (REPLACES totals, never adds to them)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day must not be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date)
    DO UPDATE SET total_weight = EXCLUDED.total_weight,
                  total_value  = EXCLUDED.total_value;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every day at 01:30, for the previous day
SELECT cron.schedule(
    'maize_refresh_purchases',
    '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- (a) Six deliveries covering grades A, B, C (loaded through the procedure)
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 2);   -- K500
CALL pr_receive_delivery(1, 'B',  50, CURRENT_DATE - 1);   -- K200
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE - 1);   -- K600
CALL pr_receive_delivery(2, 'A',  30, CURRENT_DATE - 1);   -- K150
CALL pr_receive_delivery(3, 'B',  80, CURRENT_DATE - 1);   -- K320
CALL pr_receive_delivery(3, 'C',  40, CURRENT_DATE);       -- K120

-- Both payment states: farmer 1's first delivery and all of farmer 3's are paid
-- (the trigger fires on UPDATE too and leaves the prices consistent)
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 5, 6);

SELECT * FROM deliveries ORDER BY delivery_id;

-- (b)
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
-- SELECT fn_maize_rate(NULL);   -- ERROR
-- SELECT fn_maize_rate('D');    -- ERROR: Unsupported grade

-- (c)/(d) Rejections (uncomment one at a time)
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- ERROR: unknown farmer
-- CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);    -- ERROR: invalid grade
-- CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);     -- ERROR: weight must be positive
-- Direct SQL still gets the rule (the rate and value given here are overwritten by the trigger):
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
--   VALUES (1, 'B', 10, 99, 9999, CURRENT_DATE);         -- stored as rate 4.00, value 40.00
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
--   VALUES (1, 'A', -5, 5, -25, CURRENT_DATE);           -- ERROR: weight must be positive

-- (e) Farmer 3 has nothing unpaid -> 0.00
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Repeated execution gives the same totals
CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);
SELECT * FROM daily_purchases ORDER BY purchase_date;   -- 360 kg, K1270 for yesterday

SELECT jobid, jobname, schedule, command, active FROM cron.job;
