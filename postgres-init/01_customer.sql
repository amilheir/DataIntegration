-- MINIMAL SMOKE-TEST FIXTURE ONLY (IMPROVEMENTS_SPEC DA-2).
--
-- This is public.customer from spec.md §22 — PK customer_id, watermark
-- updated_at — kept because that worked example refers to it. It is NOT part of
-- the demo path: the demo's single customer master is sample.customer
-- (02_sample_schema.sql), and showing two customer tables with different shapes
-- to a live audience is a reliable source of confusion. Mount this one only
-- when smoke-testing the §22 scenario.
--
-- Addresses are on the reserved, non-routable .invalid TLD: nothing an audience
-- sees should look like a real mailbox.
-- NOTE: varchar (not text) — the AI Hub 162 JDBC foreign-table auto-import
-- silently skips postgres text columns (see README EAP caveats)
CREATE TABLE public.customer (
    customer_id SERIAL PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    email       VARCHAR(200),
    updated_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO public.customer (name, email, updated_at) VALUES
  ('Ana Souza',      'ana.souza@demo.invalid',      now() - interval '9 days'),
  ('Bruno Lima',     'bruno.lima@demo.invalid',     now() - interval '8 days'),
  ('Carla Mendes',   'carla.mendes@demo.invalid',   now() - interval '7 days'),
  ('Diego Ferreira', 'diego.ferreira@demo.invalid', now() - interval '6 days'),
  ('Elisa Ramos',    'elisa.ramos@demo.invalid',    now() - interval '5 days'),
  ('Fabio Costa',    'fabio.costa@demo.invalid',    now() - interval '4 days'),
  ('Gabriela Nunes', 'gabriela.nunes@demo.invalid', now() - interval '3 days'),
  ('Henrique Alves', 'henrique.alves@demo.invalid', now() - interval '2 days'),
  ('Isabela Rocha',  'isabela.rocha@demo.invalid',  now() - interval '1 day'),
  ('Joao Martins',   'joao.martins@demo.invalid',   now());
