# IRIS AI ETL/ELT Wizard Builder

AI-assisted, low-code ETL/ELT wizard built entirely on **InterSystems IRIS** with the
**AI Hub EAP** (`%AI.Agent`). A user describes a data-integration goal in business terms;
the architect agent discovers the source, recommends a loading strategy, generates every
artifact (Foreign Servers/Tables, landing/staging/target DDL, merge SQL, validation rules),
and deploys and runs the pipeline in the same IRIS instance — with a real-time architecture
graph rendered from a seq-replayable event log.

Full specification: [spec.md](spec.md). ObjectScript rules for AI agents: [AGENTS.md](AGENTS.md).

**Status: P0–P5 delivered.** The metadata model, REST API, WebSocket hub with seq replay,
the declarative agent, all eight load strategies, the Interoperability production runtime,
RBAC and the docs generator are built and working, and the frontend is a complete
three-tab application — not a stub. Two things remain **unverified**, not unbuilt:
**MySQL and SQL Server** (documented as following the identical JDBC path, never tested —
no local server existed) and **scale** (one measurement exists — 541,909 rows from a 47 MB
CSV mounted and fully loaded in ~16 s on a laptop — but no benchmark suite, no server
hardware, no concurrency).

## Demo

- **[DEMO_RUNBOOK.md](DEMO_RUNBOOK.md)** — how to run the demo end to end: rules, cold
  start, preparation, verification, the step sequence, fallbacks, reset, teardown, the
  measured numbers, and the do-not-claim list. Start here.
- [EXECUTIVE_DEMO_PLAN.md](EXECUTIVE_DEMO_PLAN.md) — the business framing and rationale.
- [IMPROVEMENTS_SPEC.md](IMPROVEMENTS_SPEC.md) — the engineering delta behind the demo work.

```bash
sh scripts/demo-verify.sh    # READY, or exactly what is wrong
sh scripts/demo-reset.sh     # back to a known-good, demo-ready state
sh scripts/stop.sh           # the ONLY supported way to stop the stack
```

## Layout

```
docker-compose.yaml        IRIS (AI Hub EAP image) + optional ollama profile
Modelfile.ornith           etlwizard-ornith  \
Modelfile.gemma            etlwizard-gemma    > the three masthead picker models
Modelfile.coder            etlwizard-coder   /  (all 8192-context, spec §27.3)
Modelfile                  etlwizard-qwen (9B; needs >8 GB VRAM — see Modelfile.coder)
src-iris/
  Dockerfile               build: load + compile ETLWizard into ETLWIZARD namespace
  iris.script              namespace setup + build-161+ compile ordering
  Installer.cls            ETLWIZARD namespace, /etlwizard + /etlwizard/api web apps
  cpf/cpfmerge.cpf         CPF merge (CallIn service)
  frontend/index.html      the whole UI: one self-contained file, no build step
  dropzone/                CSV source files the wizard can mount
  src/ETLWizard/
    Model/                 Pipeline · Node · Edge · Run · Event · Watermark · PendingApproval
    API/Dispatcher.cls     %CSP.REST endpoints (spec §15)
    WS/Hub.cls             %CSP.WebSocket, {runId,lastSeq} replay protocol (spec §14)
    Agent/                 Architect (%AI.Agent) · Service · ProviderFactory · SqlGen
    Tools/                 ForeignTable · Load · Indexing · Transform · DataQuality ·
                           Catalog · Production · BulkLoad · Util
    Host/                  Interoperability hosts: ExtractService · Orchestrator · LoadOperation
    Policy/                Audit · Auth (blocking approval policy)
    Setup.cls              Config Store profiles, RBAC, demo preparation, smoke test
scripts/
  stop.sh / stop.ps1       graceful shutdown - the ONLY supported stop path
  demo-verify.sh           readiness: READY, or exactly what is wrong
  demo-reset.sh            back to a known-good, demo-ready state
  demo-newday.sh           add source rows so the incremental story is provable
  demo.ps1                 Windows entry point for the three demo scripts
  install-automl.sh        AutoML onto the durable path (reused iris-data volumes)
```

**The frontend is three tabs**, not a canvas stub:

| Tab | What it does |
|---|---|
| **Data Sources** | Standing configuration: gateway connections, foreign servers, and the tables mounted from them. Global — not tied to any one pipeline. |
| **ETL Interop** | Builds one ETL at a time from tables that already exist: pick tables → generate/edit the SQL → choose strategy, watermark and schedule → deploy, load, and optionally index. Owns the live flowchart and the results panel. |
| **ML Models** | IntegratedML workbench over any mounted table: create, train, validate, inspect metrics, predict. |

A masthead toggle switches between **Technical** and **Executive** views of the same
application — same instance, same capabilities, different audience. Set the instance
default with `do ##class(ETLWizard.Setup).SetDefaultView("executive")`.

## Quick start

1. **Load the AI Hub image** (once). The supported image is the **enterprise** AI Hub
   build `iris:2026.3.0AI.125.0` — it is what `.env` uses and what the ML tab was
   verified against:

   ```powershell
   docker image load -i .\src-iris\iris-2026.3.0AI.125.0-docker.tar.gz
   docker images   # confirm the tag, adjust IRIS_IMAGE in .env if it differs
   ```

   Enterprise means **licensed**. The build needs a key, and it must be a
   `Container(...)` platform key: an "all non-container" key (which is how the AI Hub
   EAP key ships) is rejected inside Docker with *"license file invalid for this
   platform"*, after which every REST/dispatch web app answers **503**.

2. **Configure env**: `cp .env.example .env`, then point `IRIS_KEY_PATH` and
   `IRIS_PW_FILE` at your licence key and password file. Both must live **outside**
   this directory — they reach the build as Docker secrets, never as files in the
   build context, so that no credential material sits in a directory that might be
   screen-shared.

3. **Build & run**:

   ```powershell
   docker compose --profile local-llm up -d --build
   ```

   > **On the current demo machine, use `--no-build`.** The base image is not in the
   > local cache, `docker.iscinternal.com` is not reachable from it, and the
   > `iris-2026.3.0AI.125.0-docker.tar.gz` is not on disk — so `--build` fails at
   > `FROM`. The already-built `irisetlwizard-iris:latest` is what the stack runs on.
   > See [DEMO_RUNBOOK §8b](DEMO_RUNBOOK.md); this is a real single point of failure.

4. **Configure the LLM profile** (spec §27.1) in an IRIS terminal
   (`docker compose exec iris iris session IRIS -U ETLWIZARD`):

   ```objectscript
   // Local — Ollama from the compose profile (service DNS name "ollama").
   // The three picker models are provisioned by the ollama-init service:
   //   docker compose --profile local-llm up -d
   // (or re-run just that step: docker compose --profile local-llm run --rm ollama-init)
   // One model serves both the architect and the SQL/index agents — see the
   // ConfigureLocalProfile doc comment for why they are no longer split.
   // The masthead dropdown switches between them at runtime; this just seeds
   // the starting point (ETLWizard.Setup DEFAULTAGENTMODEL).
   do ##class(ETLWizard.Setup).SetAgentModel(##class(ETLWizard.Setup).#DEFAULTAGENTMODEL, .err)

   // Local — Ollama installed on the Windows host instead:
   do ##class(ETLWizard.Setup).ConfigureLocalProfile()

   // or cloud (key via secret reference, never plain text — spec §16.4)
   do ##class(ETLWizard.Setup).ConfigureCloudProfile("anthropic","claude-sonnet-4-5","secret://AISecrets.anthropic#apikey")
   ```

5. **Smoke test** (P0 exit criteria — agent tool round-trip + event log):

   ```objectscript
   do ##class(ETLWizard.Setup).SmokeTest()
   ```

6. **Open the application**: <http://localhost:52773/etlwizard/index.html> — mount a
   source on **Data Sources**, then build an ETL on **ETL Interop**. The flowchart and
   the results panel update live; refresh mid-run and the canvas replays from the event
   log (spec §23.3).

7. **Stop the stack with `scripts/stop.sh`** (or `scripts\stop.ps1`) — never with
   `docker compose down`. IRIS does not trap `SIGTERM`, so a plain stop SIGKILLs it, the
   write image journal is never flushed, and uncheckpointed writes are rolled back with
   **no error anywhere**. `stop_grace_period` does not help; it only delays the SIGKILL.

## Known EAP caveats

- **Stopping the stack**: `docker compose down` / `docker stop` SIGKILL IRIS (it does not
  trap `SIGTERM`), leaving the WIJ unflushed and silently rolling back uncheckpointed
  writes — a verified Config Store change was lost this way. Use `scripts/stop.sh` or
  `scripts\stop.ps1`, which run `iris stop IRIS quietly` first.
- **This instance's locale is `ptbw` (pt-BR).** Two consequences that look like bugs and
  are not: IRIS returns error text in **Portuguese** (so any error-text matching must key
  on SQLCODE, never on English phrases), and every wizard-built table raises a
  collation-mismatch warning (process collation 20 vs global 5) that puts IRIS in `alert`
  and the container in `unhealthy`. Measured impact on query results: none — indexed and
  `%NOINDEX` scans agree on equality, LIKE, DISTINCT and ORDER BY. See DEMO_RUNBOOK §5c.
- **Over a FOREIGN table, `SELECT DISTINCT TOP n col` returns zero rows**, as does
  `SELECT DISTINCT col FROM (SELECT TOP n col FROM ft) x`. The plain `SELECT DISTINCT col`
  works. Cap the result while reading instead.
- **Wrapping a query over a foreign table in a derived table loses column typing.**
  `FROM (<select>) etl_t WHERE etl_t.<ts_col> > ?` matches nothing where the direct query
  matches correctly; it needs `CAST(? AS TIMESTAMP)`. This silently broke every incremental
  load after the first.
- **A foreign server is not usable from the process that created it.** The first
  `CREATE FOREIGN TABLE` against a server created moments earlier in the same session
  fails with `SQLCODE -237: Failed to craft query string for schema import`. Waiting does
  not help — it is process-local metadata. Create servers in one session and mount in
  another (this is why `scripts/demo-reset.sh` makes two `iris session` calls, and why
  `ETLWizard.Setup` splits `PrepareServers()` from `MountDemoTables()`).
- The AI builds ship **without** the private web server (no CSP
  binaries, `changePassword.sh` fails on `CSPpwd`). HTTP is therefore served by the
  `webgateway` compose service ([webgateway/webgateway-init.sh](webgateway/webgateway-init.sh)
  fixes the three known gateway bugs: CSP.ini init race, missing `[LOCAL]` credentials,
  `CSP On` directive). Port `${IRIS_PORT}` maps to the gateway, not to IRIS.
- REST web apps created by the Installer need `Recurse="1"` or only single-segment
  routes reach the dispatcher.
- Provider `base_url` values **must end with a trailing slash** (`.../v1/`): the
  provider layer URL-joins relative segments, so `.../v1` silently resolves
  `models` to `/models` → 404 (verified on build 162 against Ollama).
- JDBC foreign tables (build 162, PostgreSQL): **auto schema import silently skips
  `text` columns** (use `varchar` on the source or fall back to `THROUGH`
  materialization), and **an explicit column list yields zero rows silently** —
  always use auto-import (`CREATE FOREIGN TABLE ... SERVER s TABLE 't'` with no
  column list).
- Passthrough syntax is `THROUGH SERVER <name> SELECT ...` (the spec's §6.2
  examples omit the SERVER keyword; the parser requires it).
- FT auto-import reports `CHARACTER_MAXIMUM_LENGTH = 1` for all varchar columns —
  Load tools treat ≤1 as unknown and use VARCHAR(500).
- Layer schemas are `ETLW_LANDING/_STAGING/_TARGET` (not the spec's `ETLWIZARD_*`):
  any schema starting with `ETLWIZARD` projects to a class package that
  case-conflicts with the `ETLWizard` code package (SQLCODE -400 on CREATE TABLE).
- All `%AI.*` usage is confined to `ETLWizard.Agent`, `ETLWizard.Policy`,
  `ETLWizard.Tools` so prerelease SDK churn is absorbed in one place (spec §4.1, §20).
- `%AI.Policy` audit/auth hook signatures are introspected on the live instance before
  the custom policies are wired (P1) — the ToolSet uses `%AI.Policy.ConsoleAudit` until then.

## Roadmap (spec §21)

| Phase | Scope |
|---|---|
| P0 ✅ | Foundations: model, REST, WS replay, agent + provider profiles, catalog tools, stub canvas |
| P1 ✅ | PostgreSQL + CSV foreign tables via agent, SourceDiscovery/ForeignTable/CsvProfiling tools, approval flow (approve/reject/re-plan), audit bridge, step prompts |
| P2 ✅ | Strategy engine (§9 scoring), Load tools (layer DDL, incremental timestamp + upsert, watermarks), Transformation/DataQuality tools, metadata persistence (§12.2), steps 6–12 — §22 scenario deployed by the agent |
| P3 ✅ | Runtime executor (re-runs from §12.2 metadata, zero LLM — verified at network level), POST /pipeline/:id/run (JOBbed) + /runs history, Run-pipeline button with live canvas, run-history replay, stats banner |
| **P4 ✅** | **Interoperability Production runtime (spec v2.2 §4.3) ✅**: reusable hosts (`ETLWizard.Host.ExtractService/Orchestrator/LoadOperation`), typed `ETLWizard.Msg.*`, generated per-pipeline `ETLWizard.Prod.<base>` class (gated `GenerateProduction`), `Ens.Director` start/stop/run-now via `POST /pipeline/:id/production`, scheduling = Business Service CallInterval, every run traceable in Visual Trace. **Strategies ✅**: snapshot (dated tables), append-only + numeric watermark, CSV incremental by file arrival (processed-file registry), quarantine (`ETLW_AUDIT.<base>_quarantine` + null-PK routing). **External IRIS source ✅** via loopback JDBC (`intersystems-jdbc-3.10.5.jar` ships in the image; connection `iris_self_connection`). MySQL/SQL Server follow the identical JDBC path: drop the connector jar in `src-iris/jdbc/`, `CreateGatewayConnection(name, "jdbc:mysql://...", user, pw, "com.mysql.cj.jdbc.Driver", jarPath)`, then the same foreign-server tools. **REST ingestion ✅**: `StoreRestConfig` → `GenerateRestClient` (emits + compiles a visible `ETLWizard.Gen.Rest<base>` class landing raw JSON into `ETLW_LANDING.<base>_rest_raw`) → `RunRestCursorLoad` (cursor watermark, resume-safe); demo cursor-paged source at `GET /etlwizard/api/demo/customers?after=0&size=4`. **P4 complete** — all 8 strategies pass; sources: PostgreSQL/CSV/external-IRIS/REST verified, MySQL/MSSQL documented (identical JDBC path, no local server to verify) |
| **P5 ✅** | RBAC (`ETLWizard_User/Approver/Admin` roles + `ETLWizard.Approve:USE` enforced on approvals when `^ETLWizard("devMode")=0`), SQL lint (`LintSql`: single-statement, verb allow-list, EXACT-vs-SQLUPPER collation risk), masking suggestions (`SuggestMasking` → masked SELECT list), docs generator (`GenerateDocs` → `src-iris/docs/<pipeline>.md`), demo dataset (postgres customer + CSV dropzone, from P1) |
