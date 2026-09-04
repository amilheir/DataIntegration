-- Sample schema: employee / customer / orders, with orders referencing both.
-- This is the demo's single source of business truth (IMPROVEMENTS_SPEC DA-1/DA-2).
--
-- NOTE: varchar (not text) — the AI Hub JDBC foreign-table auto-import silently
-- skips postgres text columns (see README EAP caveats). numeric is fine and is
-- what the revenue join needs; verify it after the first mount all the same.
--
-- Identifiers are unquoted AND snake_case. Unquoted is deliberate: the wizard
-- generates SQL without quotes, and quoted mixed-case names would have to be
-- quoted everywhere. snake_case is deliberate too, and it is not cosmetic --
-- postgres folds unquoted CustomerNum to "customernum", and the local model
-- writing the demo's SQL reliably "corrects" that to customer_id, producing
-- SQL that is structurally perfect and does not compile. Measured: with the
-- old names the rehearsed demo prompt failed on EVERY attempt. Column names a
-- model would naturally guess are a demo-reliability feature, not a style
-- preference. daily_sales.csv uses the same convention.
--
-- Data is 100% synthetic and generated with generate_series rather than
-- committed as literal INSERTs, so the file stays reviewable and the dataset is
-- reproducible. No real person, company or transaction appears here; addresses
-- are on the reserved, non-routable .invalid TLD.
CREATE SCHEMA IF NOT EXISTS sample;

CREATE TABLE sample.employee (
    employee_id SERIAL PRIMARY KEY,
    name_last   VARCHAR(100) NOT NULL,
    name_first  VARCHAR(100) NOT NULL,
    start_date  DATE
);

CREATE TABLE sample.customer (
    customer_id SERIAL PRIMARY KEY,
    name       VARCHAR(200) NOT NULL,
    email      VARCHAR(200),
    region     VARCHAR(40),
    updated_at  TIMESTAMP NOT NULL DEFAULT now(),
    employee_id INTEGER REFERENCES sample.employee (employee_id)
);

CREATE TABLE sample.orders (
    order_id        SERIAL PRIMARY KEY,
    item      VARCHAR(200),
    quantity  INTEGER,
    unit_price      NUMERIC(10,2),
    -- completed / pending / cancelled, so "only completed orders" in the
    -- natural-language prompt has something real to filter on
    status         VARCHAR(20),
    customer_id    INTEGER REFERENCES sample.customer (customer_id),
    employee_id INTEGER REFERENCES sample.employee (employee_id),
    -- when the order was placed: the watermark an incremental pipeline reads
    ordered_at      TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- employees
-- 30 account owners, start dates spread over roughly eight years.
INSERT INTO sample.employee (name_last, name_first, start_date)
SELECT
  (ARRAY['Aldridge','Barros','Chandra','Delacroix','Eriksen','Fontaine','Gallagher',
         'Haverstock','Ibarra','Jorgensen','Kowalski','Lindqvist','Mbeki','Novak',
         'Okonkwo','Pereira','Quintero','Rasmussen','Sandoval','Thorne','Ueda',
         'Vasquez','Whitfield','Ximenes','Yamamoto','Zielinski','Abernathy',
         'Bergstrom','Castellanos','Dunmore'])[g],
  (ARRAY['Alice','Bruno','Chandra','Delphine','Erik','Fiona','Gavin','Helena',
         'Ines','Jonas','Karin','Lucas','Mariam','Nils','Olu','Paula','Quentin',
         'Rosa','Sven','Tomas','Ulla','Vera','Wesley','Xenia','Yusuf','Zara',
         'Adam','Beatriz','Caleb','Dora'])[g],
  DATE '2018-01-08' + ((g * 97) % 2900)
FROM generate_series(1, 30) AS g;

-- ---------------------------------------------------------------- customers
-- 500 plausible business names across five regions. employee_id is deliberately
-- lopsided (real account books are), and updated_at is spread across 90 days so
-- an incremental-by-timestamp pipeline has a meaningful window.
INSERT INTO sample.customer (name, email, region, updated_at, employee_id)
SELECT
  (ARRAY['Northwind','Harbourline','Cedarcrest','Blue Ridge','Ironvale','Summit',
         'Lakeshore','Kestrel','Granite','Meridian','Foxglove','Sablewood',
         'Pinehurst','Silverbrook','Alderway','Copperfield','Marlowe','Ravensgate',
         'Thistledown','Windermere'])[1 + (g % 20)]
    || ' ' ||
  (ARRAY['Logistics','Foods','Analytics','Textiles','Medical','Robotics',
         'Freight','Ceramics','Instruments','Chemicals'])[1 + ((g / 20) % 10)]
    || ' ' ||
  (ARRAY['Ltd','GmbH','SA','Inc','BV'])[1 + ((g / 7) % 5)],
  'accounts' || g || '@' ||
    lower((ARRAY['northwind','harbourline','cedarcrest','blueridge','ironvale',
                 'summit','lakeshore','kestrel','granite','meridian','foxglove',
                 'sablewood','pinehurst','silverbrook','alderway','copperfield',
                 'marlowe','ravensgate','thistledown','windermere'])[1 + (g % 20)])
    || '.invalid',
  (ARRAY['North America','EMEA','LATAM','APAC','UK & Ireland'])[1 + (g % 5)],
  -- 90-day spread, weighted towards recent so "what changed lately" is visible
  now() - (((g * 37) % 90) || ' days')::interval - ((g % 24) || ' hours')::interval,
  -- lopsided book: a third of the customers sit with the first five reps
  CASE WHEN g % 3 = 0 THEN 1 + (g % 5) ELSE 1 + (g % 30) END
FROM generate_series(1, 500) AS g;

-- ------------------------------------------------------------------- orders
-- ~6,000 orders across the last 12 months, with visible seasonality: the
-- per-month counts below peak in the run-up to the year end and dip in the
-- northern summer. ordered_at is the watermark column.
--
-- Customer selection is power-law (random()^3), so revenue per customer is a
-- long tail rather than a flat distribution — which is the whole point of the
-- customer-revenue join the demo builds.
-- status carries a DELIBERATE, LEARNABLE SIGNAL. This matters: with a purely
-- random status a model trained on this table can only ever score at chance
-- (measured: 45% accuracy, 0.54 ROC-AUC), and the ML segment of the demo then
-- argues against itself on screen. The rule below is the kind of pattern a real
-- business has - big-ticket orders stall or fall through more often, and one
-- region is worse than the others - plus genuine noise, so the model has
-- something real to find and is not simply memorising an arithmetic identity.
INSERT INTO sample.orders (item, quantity, unit_price, status, customer_id, employee_id, ordered_at)
SELECT
  (ARRAY['Pallet rack','Conveyor belt','Label printer','Barcode scanner',
         'Cold-chain container','Forklift battery','Shrink wrapper',
         'Weighing station','Dock leveller','Tote bin','Strapping machine',
         'Handheld terminal','Safety cage','Sorting arm'])[1 + (s.n % 14)],
  s.qty,
  s.price,
  -- risk rises with order value and is worse in one region; ~0.10 of noise
  -- keeps it a prediction rather than a lookup
  CASE
    WHEN random() < (0.03
                     + 0.55 * least(1.0, (s.qty * s.price) / 9000.0)
                     + CASE WHEN c.region = 'LATAM' THEN 0.15 ELSE 0 END)
      THEN CASE WHEN random() < 0.55 THEN 'pending' ELSE 'cancelled' END
    ELSE 'completed'
  END,
  c.customer_id,
  -- the rep who owns the customer places most of that customer's orders
  CASE WHEN random() < 0.85 THEN c.employee_id ELSE 1 + (s.n % 30) END,
  -- somewhere inside month m, counting back from today.
  --
  -- LEAST(..., now() - 5 minutes) is load-bearing, not defensive. The current
  -- month's window runs from the 1st plus up to 27 days plus up to a day of
  -- seconds, which lands PAST today whenever the month is young - and a single
  -- future-dated order becomes max(ordered_at), i.e. the watermark. Every row
  -- demo-newday.sh then adds is dated now(), falls BELOW that watermark, and
  -- the second pipeline run loads nothing while reporting success. Measured:
  -- exactly 1 future row was enough to break the whole incremental story.
  LEAST(
    date_trunc('month', now()) - ((12 - s.m) || ' months')::interval
      + ((random() * 27) || ' days')::interval
      + ((random() * 86000) || ' seconds')::interval,
    now() - interval '5 minutes')
FROM (
  -- the customer draw is made in this select list, one evaluation per row. An
  -- uncorrelated LATERAL or a volatile WHERE clause would be evaluated once for
  -- the whole scan and hand every order to the same handful of customers.
  -- qty and price are drawn here too, because the status rule below has to read
  -- the SAME values that get inserted.
  SELECT m, n,
         1 + floor(500 * power(random(), 3))::int AS cid,
         1 + (n % 25) AS qty,
         round((18 + (random() * 940))::numeric, 2) AS price
  FROM (
    SELECT m, generate_series(1, cnt) AS n
    FROM unnest(ARRAY[430,390,410,470,520,480,360,340,520,610,700,780]) WITH ORDINALITY AS t(cnt, m)
  ) AS months
) AS s
JOIN sample.customer c ON c.customer_id = s.cid;

-- --------------------------------------------------------- quarantine fodder
-- DA-5: a small, deliberate set of defective rows so "what happens to bad
-- data?" is answered by demonstration rather than assertion. Kept small enough
-- that the target row count still looks clean.
--
-- 10 rows with no customer reference at all.
INSERT INTO sample.orders (item, quantity, unit_price, status, customer_id, employee_id, ordered_at)
SELECT 'Tote bin', 1 + (g % 9), 42.50, 'completed', NULL, 1 + (g % 30),
       now() - ((g * 3) || ' days')::interval
FROM generate_series(1, 10) AS g;

-- 4 rows whose order date is outside any plausible business range.
--
-- All four are in the PAST on purpose. A future-dated row would become
-- max(ordered_at), and an incremental_timestamp pipeline would set its watermark
-- to that value on the first run and then never see another new row again —
-- silently breaking the incremental demo (DA-3) rather than demonstrating
-- quarantine.
INSERT INTO sample.orders (item, quantity, unit_price, status, customer_id, employee_id, ordered_at)
VALUES
  ('Label printer',     2, 310.00, 'completed', 12, 3,  TIMESTAMP '1899-12-31 00:00:00'),
  ('Conveyor belt',     1, 880.00, 'completed', 48, 7,  TIMESTAMP '1900-01-01 00:00:00'),
  ('Handheld terminal', 5, 120.00, 'pending',   91, 11, TIMESTAMP '1901-01-01 00:00:00'),
  ('Safety cage',       1, 640.00, 'completed', 7,  2,  TIMESTAMP '1902-01-01 00:00:00');

-- Indexes the demo's own joins lean on. The wizard's index advisor operates on
-- the IRIS target; these are source-side and keep preview/discovery snappy.
CREATE INDEX orders_orderedat_idx ON sample.orders (ordered_at);
CREATE INDEX orders_customernum_idx ON sample.orders (customer_id);
CREATE INDEX customer_updatedat_idx ON sample.customer (updated_at);
