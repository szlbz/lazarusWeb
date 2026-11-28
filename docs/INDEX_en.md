# lazarusWeb Documentation Index

> Find documents by scenario. lazarusWeb is the web-ification runtime for Lazarus/FPC desktop programs:
> change the business form's base class to `TLWForm`, compile with `--ws=nogui`, and in the browser it's the original program
> (default Alpine.js rendering, optional Ext JS; the server keeps a real LCL control tree).

## I want to...

| Scenario | Read these |
|---|---|
| First contact, run it and see | `README.md` (root directory) quick start → `MANUAL_en.md` Usage Part |
| Introduce it to others / evaluate whether to use it (features, highlights, boundaries in one page) | `FEATURES_en.md` |
| Deploy to production (HTTPS/reverse proxy/cluster) | `deploy/README.md`, `deploy/nginx.conf`, `WHYPER_en.md` |
| Run the server as a Windows service (boot start / standard operations) | `WINDOWS_SERVICE_en.md` (**choose "Service (daemon) mode" in dialog 1 of the New Project wizard**, or use `tools\lwnew --service`; compile → install/start/stop in cmd and PowerShell → config → troubleshooting → internals; example `demos/service_demo/`) |
| What the service is called / how to rename it / common `sc` commands | `SERVICE_NAMING_en.md` (both routes follow the final project name: CLI from `--name`, IDE wizard rewrites the mapper before disk write with the name entered at Ctrl+S; display name, rename + reinstall, ini file casing) |
| Run multiple workers with the load balancer (parameters/CLI/GUI/hot update) | `WHYPER_en.md` (lwhyper usage guide) |
| Understand how lwhyper distributes requests (stickiness/round-robin/failover/WS passthrough) | `LOADBALANCE_en.md` (load balancing explained) |
| Release a new version without downtime (hot update) | `WHYPER_en.md` §5.1 (usage/ops playbook) → §5.2 (implementation mechanism); graceful worker shutdown see `NOTES.md` pitfall 175 |
| Understand the architecture and working principles | `ARCHITECTURE_en.md` (overview) → `HOW_IT_WORKS_en.md` (deep dive) |
| Check whether a control can be used | `CONTROL_MATRIX_en.md` (auto-generated) → `MAPPING_en.md` (mapping details) |
| Check DB-aware controls | `DB_AWARE_MATRIX_en.md`, `MAPPING_en.md` data controls section |
| Concerned about security / SQL injection (framework trust boundary, parameterized examples) | `SECURITY_en.md` (framework has no SQL channel; risk lies in business code concatenating SQL) |
| Want to add features without touching the main program / ask how DLL·SO plugins work | **First read `PLUGIN_GUIDE_en.md`** (step by step: add a page, integrate into your own project, `.lfm`, FAQ); principles and four-scheme comparison in `PLUGIN_FEASIBILITY_en.md` |
| Convert an existing LCL project to Web | `tools/lwconvert.exe`, regression see `tests/t_convert.py` |
| Create a new project from scratch (IDE wizard: three dialogs — application mode normal/service, widgetset GUI/nogui, template normal/plugin) | `MANUAL_en.md` Usage Part "Create a new project with the IDE wizard"; quick reference see `README_en.md` "Create a project with the wizard in the IDE" |
| Change colors / add a color scheme (Alpine layer, 7 ready-made) | `MANUAL_en.md` §5.1 (user perspective) → `NOTES.md` pitfall 174 (three conventions for adding a theme) |
| Performance and capacity | `BENCH_en.md` (empirical data), `SCALE_en.md` (optimization roadmap) |
| Troubleshoot difficult issues | `DEBUGGING_en.md` (case methodology) → `NOTES.md` search by pitfall number |
| Mobile browser adaptation (principles and implementation record) | `MOBILE_en.md` §8 (detection signals / empirical data) |
| Photo upload (phone system camera / desktop webcam capture) | `MANUAL_en.md` Usage Part "Photo: TLWCamera" + `demos/mobile_demo` |
| Gallery grid unsaved-close prompt / gridsave.json save-load | `ugallery_beforeunload_unsaved_changes_en.md` (7 changes itemized; Chinese version `ugallery关闭浏览器未保存提示-修改说明.md`); implementation details in `NOTES.md` pitfall 194 |
| Write layout templates for forms (window popup / flat full page) | `MANUAL_en.md` Part Two "16. Form Template Development Guide (Window + Flat)"; desktop `<form name>.html` (shared by both modes) + mobile `<form name>.m.html`, file header `lw-tpl-mode` marker, controls not reflowed; skeleton generated from .lfm with one click via the IDE Tools menu (see 16.0) |
| Compare with uniGUI | `COMPARISON_unigui_en.md` |
| Dual FPC versions (3.2.2 / 3.3.1) merge and consistency audit | `MERGE_AUDIT_en.md` (src/core first round) → `MERGE_AUDIT_FULL_en.md` (src+demos+tools full) |
| Write/extend the framework itself | `MANUAL_en.md` Development Part + `HOW_IT_WORKS_en.md` |
| Add browser bindings for third-party / self-written controls | mechanism overview `THIRDPARTY_BINDING_en.md` → complete example `THIRDPARTY_BINDING_TCHART_en.md` (using a real TAChart TChart as example, including nogui construction test, six-step integration, type pitfalls) |
| Do multilingual / switch UI between Chinese and English | `I18N_PO_en.md` (Lazarus PO mode: original text as msgid, `--lang=`/`?lwlang=`, flow for adding text, capability boundaries) |

## Complete Document List

| File | Content | Maintenance |
|---|---|---|
| `../README.md` | Project main entry: quick start/parameters/INI/deployment/control statistics | handwritten (**sole source of the parameter table**) |
| `FEATURES_en.md` | **Features and highlights**: eleven capabilities, seven "decisions done right", numbers at a glance, comparison with uniGUI, applicability boundaries, five-minute self-verification | handwritten (volatile numbers carry dates) |
| `MANUAL_en.md` | User manual (Usage Part + Development Part) | handwritten |
| `THIRDPARTY_BINDING_en.md` | Add browser bindings for third-party controls: mechanism overview, six-step integration, technical risks | handwritten |
| `THIRDPARTY_BINDING_TCHART_en.md` | Complete example: binding a real TAChart TChart into lazarusWeb (nogui test + copyable code + pitfalls) | handwritten (2026-11-19) |
| `ARCHITECTURE_en.md` | Technical decisions, module implementation, threading model | handwritten |
| `HOW_IT_WORKS_en.md` | The complete round trip of one click, ShowModal, reconcile | handwritten (2026-11-11 snapshot) |
| `MAPPING_en.md` | Control/property/event mapping, dialogs, upload/download | handwritten |
| `CONTROL_MATRIX_en.md` | 66 visual controls empirical matrix | auto-generated by `tools/lwaudit` |
| `DB_AWARE_MATRIX_en.md` | 12 DB controls empirical matrix | auto-generated by `tools/lwdbcheck` |
| `SECURITY_en.md` | Security notes: SQL injection and trust boundary (framework has no SQL channel, demo parameterized examples, business-code self-check list) | handwritten |
| `PLUGIN_GUIDE_en.md` | Plugin usage guide: 30-second concept, run the demo, 5 steps to add a page, integrate into your own project, three `.lfm` caveats, AJAX, deployment, FAQ table | handwritten (commands consistent with the demo) |
| `PLUGIN_FEASIBILITY_en.md` | Plugin feasibility: cross-DLL class identity test, four-scheme comparison (bare DLL/process-level/Runtime Package/source plugin), phase 0 implementation (design form with `.lfm` or build form in pure code), phased roadmap and to-be-verified checklist | handwritten (empirical data carries environment) |
| `BENCH_en.md` | Load-test methods and empirical data | handwritten |
| `SCALE_en.md` | Throughput optimization roadmap (incremental patches/lwhyper) | handwritten |
| `WHYPER_en.md` | lwhyper usage guide: parameters/CLI/GUI/own endpoints/hot update (§5.1 usage, §5.2 mechanism)/troubleshooting | handwritten (**sole source of lwhyper parameters and usage**) |
| `LOADBALANCE_en.md` | lwhyper load balancing explained: why application layer is required, sid stickiness table, round-robin skipping dead nodes, probes and warm-up gate, WS passthrough, single-point semantics, observability and regression | handwritten (**sole source of the load balancing mechanism**) |
| `NOTES.md` | Pitfall records (append-only, numbered up to pitfall 212; places where old conclusions are revised by new pitfalls are marked) | handwritten |
| `WINDOWS_SERVICE_en.md` | Run the server as a Windows service: three generation routes (wizard dialog 1 / `lwnew --service` / copy the demo), quick start, cmd and PowerShell install/ops commands, configuration, CLI branching, boot start and recovery, troubleshooting (the `sc` alias, fake-alive, `CreateNew` and `Register` pitfalls), internals, moving it into your own project, host comparison, verification checklist | handwritten (2026-11-20, demo `demos/service_demo/`) |
| `SERVICE_NAMING_en.md` | What the generated service is called: both routes follow the final project name (CLI `--name` / wizard rewrites the mapper before disk write), display name / description / exe comparison, rename + reinstall, common `sc.exe` commands, fixed ini name `lazarusWeb.ini` and its casing/lookup order | handwritten (2026-11-20 verified against `C:\3`; 2026-11-21 wizard now follows the project name) |
| `AUDIT_DOC_SOURCE_2026-11-21.md` | Doc–source consistency audit (Chinese): 19 fixed mismatches (service name / defaults / three-dialog wizard / upload paths / pitfall numbers, CN+EN synchronized), 5 source-side todos (source code untouched), verified-consistent items and follow-up advice | handwritten (2026-11-21) |
| `AUDIT_DOC_SOURCE_2026-11-28.md` | Doc–source re-audit (Chinese): 43 broken references repointed, PWA parameters added to README table, new documents indexed, pitfall count updated to 212; documentation only | handwritten (2026-11-28) |
| `MERGE_AUDIT_en.md` | Feature-level audit of the 3.2.2 compatibility branch merge (method/per-file conclusions/reverted items/verification matrix) | handwritten |
| `MERGE_AUDIT_FULL_en.md` | Pre/post-merge whole-repository (src+demos+tools) feature-loss audit: five layers of symbol-level/literal-level/conditional expansion/compilation/regression | handwritten |
| `DEBUGGING_en.md` | 4 real bug tracing cases + debugging methodology | handwritten |
| `AUDIT_LFM_en.md` | lfm chain audit snapshot (conclusions merged into pitfall 69) | handwritten |
| `COMPARISON_unigui_en.md` | Feature comparison with uniGUI | handwritten |
| `MOBILE_en.md` | Mobile browser adaptation: feasibility analysis archive + Scheme B implementation record (adaptive detection/mobile templates/pan fallback) | handwritten (status line and section 8 updated with implementation) |
| `I18N_PO_en.md` | Multilingual (Chinese/English): how the PO mode lands, why the original text is the msgid, three output gates, per-session language switching, flow for adding text, capability boundaries, self-test | handwritten (translation source in `tools/i18n/`) |
| `../deploy/README.md` | Deployment guide (nginx/Caddy/Linux/systemd) | handwritten |

## Three Maintenance Rules

1. **Single source of truth**: the parameter table only in README, lwhyper's **parameters and usage** only in WHYPER_en, lwhyper's **distribution mechanism** only in LOADBALANCE_en, empirical matrices only in auto-generated files — other documents only link, don't copy. About half of the issues found in this cleanup stem from "the same fact maintained in two places with only one side updated".
2. **Snapshots carry timestamps**: volatile numbers such as line counts, unit counts, test item counts, control statistics must be written with "as of date X", or link directly to the auto-generated artifact.
3. **Revisions must be written back**: in append-only documents like NOTES, when an old pitfall is overturned by a new one (pitfall 23→41, pitfall 66→69, BENCH_en 55→155), add a strikethrough + pointer at the original place, so readers don't operate per the old scheme.
