# IRIS AI ETL/ELT Wizard Builder

AI-assisted, low-code ETL/ELT wizard built entirely on **InterSystems IRIS** with the
**AI Hub EAP** (`%AI.Agent`). A user describes a data-integration goal in business terms;
the architect agent discovers the source, recommends a loading strategy, generates every
artifact (Foreign Servers/Tables, landing/staging/target DDL, merge SQL, validation rules),
and deploys and runs the pipeline in the same IRIS instance — with a real-time architecture
graph rendered from a seq-replayable event log.

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
