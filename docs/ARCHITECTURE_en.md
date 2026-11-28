# lazarusWeb Technical Documentation — Technical Path · Implementation Methods · Usage Guide

> Version 0.9.6 · Updated 2026-11-16
> Companion documents: `README.md` (quick start), `docs/COMPARISON_unigui_en.md` (comparison with uniGUI),
> `docs/CONTROL_MATRIX_en.md` / `docs/DB_AWARE_MATRIX_en.md` (measured control-support matrices),
> `docs/NOTES.md` (a record of 212 pitfalls; outdated conclusions such as pitfalls 23/66/108 have been revised by later pitfalls), `deploy/README.md` (HTTPS / reverse proxy / clustering).

---

## I. Technical Path

### 1.1 Positioning

lazarusWeb is a **web runtime for Lazarus desktop applications**: it serializes the actually-running LCL control tree
into a browser interface — **Alpine.js rendering layer by default** (built-in dependency, zero extra deployment),
**with Ext JS as an optional rendering layer** (bring your own `ext-<version>/` and explicitly enable it with `--client=ext`).
A business program only changes one base-class line (`TForm` → `TLWForm`); events, properties, and `.lfm` are all preserved as-is,
allowing it to run in the browser as a server application.

### 1.2 Design Rationale (Why This Path)

| Candidate approach | Conclusion |
|---|---|
| Delphi/uniGUI-style shadow control systems | Commercial licensing; controls are "shadow subclasses," and the IDE designer experience is limited |
| Rewriting business logic in a pure front-end framework (Vue/React) | Zero reuse of business code, equivalent to redoing everything |
| **Real LCL control tree + serialization (this solution)** | 100% reuse of business code; TForm descendants are designed normally in the IDE; RTTI is available out of the box |

Three key decisions:

1. **TForm descendants, not proxy classes**. `TLWForm` is a genuine `TForm` descendant, and the TButton/TEdit
   dragged onto it are LCL's own controls — the property inspector, events tab, anchors, and alignment tools all work as usual,
   and the layout in the designer is the layout in the browser.
2. **nogui widgetset as a "virtual display"**. The server is compiled with `--ws=nogui`; controls are really created,
   properties and events are really maintained — there is just no screen. The missing GDI facilities are supplied by the `lwws.pas` patch.
3. **Server-authoritative, browser renders only**. The control tree, state, and event routing are all on the server;
   on the browser side, `lw-alpine.js` (with `alpine.min.js`) by default renders the JSON tree into native
   DOM/CSS and performs incremental reconciliation; the optional Ext layer is rendered into Ext components by `lw.js`,
   with both layers sharing the same JSON protocol and event/push channels.

### 1.3 Overall Architecture

```
Browser (Alpine.js 3.14.9 default / Ext JS optional)   Server (FPC 3.3.1 + Lazarus, nogui)
┌────────────────────────────────┐  WS/long-poll ┌────────────────────────────────┐
│ lw-alpine.js (default)          │  JSON         │ lwhttp   fphttpserver multithread │
│  native DOM/CSS + Alpine dirs   │ ←──────────→  │ lwsession one LCL tree per tab    │
│  optional: lw.js → Ext comps    │  HTTP         │ lwwriter  LCL tree → JSON         │
│  reconcile incremental sync     │               │ lwdispatch event → RTTI → business │
│  WS only carries event req/resp │               │ lwws     nogui patch (virtual scr) │
│  long-poll cursor unified push  │               │                                  │
└────────────────────────────────┘               └────────────────────────────────┘
```

The line counts of the server core units and the browser-side rendering scripts are from an early snapshot (both the default layer lw-alpine.js and
the optional layer lw.js continue to evolve); exact line counts are not maintained here; see 2.3 for the responsibilities of each layer.

### 1.4 Mobile Technical Path (Adaptive + Form Templates, Zero Server Changes)

Mobile/narrow-window adaptation follows the same worldview: **server-authoritative, the browser only handles presentation** — device
detection, templates, and layout are all done in the rendering layer; business Pascal code is unchanged, and server
units require zero changes (implementation details in 2.14; guide in `MOBILE_en.md` / `MANUAL_en.md` Part II §16).

| Candidate approach | Conclusion |
|---|---|
| Server-side UA detection + dual-tree delivery | Putting detection on the server opens a maintenance hole, and UA is unreliable — shrinking a desktop window still causes misdetection |
| Uniform proportional scaling (transform scale) | On a 390px screen, font size drops to about 0.3× and becomes unreadable (rejected after testing, pitfall 150) |
| Fluid reflow (custom layout engine) | Heavy engineering effort, conflicts with design-time anchored layout, high long-term maintenance cost |
| **Front-end adaptation + form-level HTML templates (this solution)** | Detection/templates/fallback all on the client; templates are optional for business code and it works without them |

Four key decisions:

1. **Three detection variables kept separate, all on the front end**: `layout` (viewport width + hysteresis: enter at ≤834 /
   exit at ≥1100), `input` (touch capability), and `capability` (fallback) are each judged independently,
   with root markers attached to `html`; the server never knows what the device is from start to finish;
2. **Templates split by platform into separate files + mode markers**: desktop window and flat modes share
   `<root>\tpl\<form name>.html`, while mobile uses `<form name>.m.html` (both files serve only as
   background/decoration layers). The file header contains `lw-tpl-mode:window|flat` (when both markers coexist, flat takes precedence).
   Templates **do not reflow controls**; controls are always absolutely positioned per the LFM's `Left/Top`, and the server only does
   static file delivery;
3. **No relocation, no change to logical parents**: both `S.P[id]` and the DOM parent remain unchanged, so the incremental patch mechanism
   is completely unaffected; if a template is missing or fails to parse, the whole thing falls back to the design-time layout — never a half-set;
4. **No template is still a first-class citizen**: forms without a template remain WYSIWYG on both platforms
   (desktop = absolute positioning as-is; mobile = pan mode, design dimensions as-is, `#lw-root` scrolling,
   no font shrinking), ensuring any old program works out of the box with behavior exactly as before.

**How desktop ↔ mobile adaptation is achieved (mechanism overview)**:

1. **Detection**: three variables kept separate, all on the front end. `layout` is judged by viewport width + hysteresis
   (enter mobile at ≤834px / exit at ≥1100px / hold in between, to prevent jitter while dragging); `input` uses
   `any-pointer:coarse` + `hover:none` to detect touch; `capability` is fallback only and does not participate.
   Results are attached as root markers `html[data-lw-layout]` / `html[data-lw-input]`,
   read live via `matchMedia` + deduplicated with rAF; hard override `?layout=` →
   `sessionStorage['lw-layout']` → `LW.layout.set()`, with the highest priority;
2. **Template configured → background decoration layer**: the client fetches the same-named `.html`, and the file-header marker
   decides floating-window or full-page flat mode; the template is inserted as a `.lw-tpl` background layer at the very front of the client area,
   with `pointer-events:none`; control DOM is untouched, drawn at design-time absolute coordinates;
   flat mode has no title bar/border/drag/resize, and width/height take max(design value, viewport) (narrow screens keep
   the design width and pan to view the overflow — squeezing down to the viewport width would clip the right-side controls), while window mode keeps the original geometry;
3. **No template → design-time WYSIWYG**: desktop absolute positioning as-is; mobile pan mode
   (design dimensions as-is, left-aligned, drag disabled, `#lw-root` scrolling, `html[data-lw-pan]`);
4. **Individual controls change form**: CSS switches based on `data-lw-layout`/`data-lw-input`,
   e.g. TUpDown with up/down arrows on desktop / −/+ large touch areas on mobile (pitfall 152).

Business code remains completely unchanged; to make a single-column mobile version of a form, you only need to add one template file
(takes effect after a refresh), see `demos/mobile_demo` for an example. End-to-end details in 2.14.

---

## II. Implementation Methods (by Module)

### 2.1 lwws.pas — nogui widgetset Patch (the Foundation of the Whole Solution)

The nogui widgetset lacks a display and a canvas, so calling `TForm.Create` directly causes an AV (pitfall 1). The patch provides:

- **Virtual display**: a fixed 96 DPI screen size, so `Form.Show/Visible` no longer divides by zero (pitfall 4);
- **Empty WS class registration**: widgetset classes that declare an "empty set of event capabilities" for all controls, so construction doesn't crash (pitfall 3/17.2);
- **GDI completion**: minimal implementations of facilities missing under nogui, such as menus and bitmap primitives;
- All wrapped in `{$IFDEF LCLnogui}`, degrading to empty implementations under non-nogui — so the package can compile directly in the IDE,
  but the project must still use `--ws=nogui` (pitfalls 15/19).

### 2.2 lwwriter.pas — LCL Tree → JSON (1337 lines)

Reflectively traverses the form's control tree, serializing each control into `{id, kind, props, children}`:

- Properties are output according to a **whitelist mapping table** (not a full RTTI dump); see `docs/MAPPING_en.md` for the mappings;
- Event capabilities are declared via a class-reference table (Click/Change/DblClick/KeyPress…);
- Incremental output: the tree carries a `seq`, and the browser diffs by id, updating only changed nodes (reconcile);
- Special controls have dedicated serialization branches: the Items/Rows structures of `TRadioGroup/TCheckGroup/TValueListEditor`
  (pitfall 25), the node tree of `TTreeView`, the rows and columns of `TStringGrid`, etc.

### 2.3 lw-alpine.js — Default Browser-side Rendering and Reconciliation (Alpine.js Layer)

- Maps `kind` to **native HTML/CSS + Alpine directives** (the default layer covers all common visual controls,
  including SVG rendering for grid/tree/chart); `alpine.min.js` is shipped with the package, no CDN involved;
- **reconcile**: when a new tree arrives, reconcile by id; unchanged DOM instances are left untouched (preserving input focus);
- Event capture: DOM events carry `id/ev/val` (sent as WS frames when connected via WS, otherwise `POST /lw/api/event`);
- **Form templates (sharing the same files as the Ext layer, see 2.14) and mobile adaptation**: mode detection,
  background decoration layers, and full-page/floating-window rendering are all done on the client; without a template, design-time WYSIWYG is preserved;
  mobile breakpoints/pan fallback are unique to this layer;
- **Long polling `/lw/api/poll` is the only push channel**: pushes are uniformly enqueued in the session queue with sequence numbers (modal/message box/overlay/download directives), and each tab fetches its own with an `after` cursor;
- **WebSocket `/lw/ws` carries only event requests/responses**: once connected, events go through WS frames (long polling keeps running), and on disconnect automatically fall back to HTTP `/lw/api/event`;
- Session ownership: sid stored in **sessionStorage** (tab level). A refresh stays in the same session;
  **closing the tab invalidates it** (re-login on next open); a new tab is an independent session by default.
  `/lw/api/attach` remains: opening explicitly with the same sid (on refresh, or when the business passes the
  sid to a new tab) attaches to the existing session, with each fetching its own pushes by cursor.
  `localStorage['lw.persist']='1'` can change this to persist across tabs/across restarts.

**Optional Ext rendering layer**: `lw.js` + `ext-<version>/` maps the same JSON into an Ext component tree,
requiring explicit enabling via `--client=ext` (or `?client=ext`) and bringing your own Ext distribution. Both layers share the above
reconcile, event, push, and session protocols; the only difference is the DOM construction approach and styling system.
Both layers share the same set of form templates (`lw-tpl-mode:window|flat`, controls keep design-time absolute coordinates,
flat-mode width/height no less than the design values), while mobile `.m.html` loading and breakpoint/pan fallback exist only in the Alpine layer.

### 2.4 lwsession.pas — Sessions and Synchronous Modals (976 lines)

- **One `TLWSession` per browser tab**, holding a form list (`FForms`);
- The `Sweep` thread cleans up expired sessions at minute granularity;
- **Synchronous modals are the core challenge**: `ShowModal` is not a nested message loop (the server has no message loop),
  but rather "push modal directive → `TEvent.WaitFor` suspends the request thread → browser clicks close → wake up".
  The semantics are exactly the same as desktop modals: the line `if f.ShowModal = mrOk then ...` really waits for the user to click (pitfalls 5/6);
- Pushes go through a **session queue with sequence numbers** (cursor protocol, pitfall 33): each tab fetches its own with `poll?after=N`;
  dialog directives are targeted with `to=<tab identifier>`, so only the initiating tab pops up the dialog;
- Closing a window automatically returns to the login page: when `VisibleWebFormCount = 0` and a LoginForm exists, automatically
  `SessionShowForm(LoginForm)` (pitfall 35.4, fixes "must restart the service to log in again after closing a window").

### 2.5 lwdispatch.pas — Event → RTTI (752 lines)

- `POST /lw/api/event` with `{sid,id,ev,val}` → locate the control in the session → **write the value back to the control first**
  (`val` writes Text/Checked/ItemIndex…, and grids also have `row/col/vals` cell editing) →
  use RTTI to find and trigger the published event method;
- Thread model: fphttpserver uses one thread per request, and event handling occurs in that request thread —
  this is precisely the prerequisite that makes synchronous modals able to "block and wait";
- Lazy-loaded tabs: element-level events on unrendered controls must be attached to a proxy element (pitfall 34).

### 2.6 lwhttp.pas — HTTP Server and Routing (1448 lines)

fphttpserver multithreaded server, route table:

| Route | Description |
|---|---|
| `GET /` | UI shell (overridable with `?form=?ext=?theme=?fresh=1`) |
| `POST /lw/api/session` | Create a new session → tree + sid + seq |
| `GET /lw/api/attach?sid=` | New tab attaches to an existing session (expired returns 410 + `gone`) |
| `GET /lw/api/tree?sid=` | Current component tree |
| `POST /lw/api/event` | Event → RTTI → new tree |
| `GET /lw/api/poll?sid=&after=` | Long polling (cursor-style push queue) |
| `GET /lw/api/log?sid=` | Session log (Show/ShowModal/EndModal all recorded) |
| `POST /lw/api/close` | End session |
| `POST /lw/api/upload?sid=&id=` | multipart upload → new tree |
| `GET /lw/download?t=` | One-time token download (no server path appears in the URL) |
| `GET /lw/ajax/<name>` | Custom AJAX endpoint (registered by lwajax) |
| `GET /lw/healthz` | Health probe `{"ok":true,"sessions":..,"uptime":..}` |
| `GET /lw/tpl/<name>.html`, `.m.html` | Form layout templates (the desktop `.html` is a single file shared by window/flat modes, mobile reads only `.m.html`; file-header `lw-tpl-mode` marker): `<root>\tpl\` → `<exe dir>\tpl\` two-level fallback, blocks path traversal (403), responds no-store (edit the template and refresh to take effect); also remains compatible by probing the legacy `.flat.html` (if present, flat takes priority); when a template is missing, wholly falls back to the design-time layout |
| `GET /lw/lw-alpine.js, /lw/alpine.min.js…` | Default Alpine layer scripts/styles (lw-alpine.js / lw-alpine.css / alpine.min.js) |
| `GET /lw/lw.js, /lw/lw.css` | Optional Ext layer scripts/styles (only loaded with `--client=ext`) |
| `GET /ext/<version>/...` | Optional Ext JS static resources (any version directory, see below; not requested when Ext is not deployed) |
| `GET /lw/ws` | WebSocket upgrade (fphttpserver trunk, pitfall 26) |

Static resource/root directory resolution has multiple levels of fallback (pitfall 30): current working directory → 5 levels up from the exe →
explicitly specified by `--root=`. With `--trust-proxy`, the client IP is taken from `X-Forwarded-For`.

**Ext directory resolution is version-independent** (pitfall 40, only needed for the optional Ext layer): the version segment in the URL is just
a "directory name," no longer bound to specific version numbers like 7.0.0 / x.x.x. A default Alpine deployment
has no `ext-*` directories and does not request the `/ext/` route.

```
ExtRootFor(ver):
  1. <root>\ext-<ver> exists                 -> use it (strict match)
  2. otherwise, exactly one ext-* under root -> fall back (only one version installed, name doesn't matter)
  3. otherwise                               -> 404 (never guess when multiple versions coexist)
```

The version segment only allows `[0-9A-Za-z._-]` (and length ≤ 32); `..`/`:`/`\` always return 403 — using
"the directory actually exists" replaces the original version whitelist, with equivalent security and no need to change code to add a version.
Similarly: the charts package decides whether to inject based on whether `ext-<ver>/build/.../charts.js` exists, and the theme falls back
crisp → classic → neptune based on whether the CSS trio exists; no version numbers are hardcoded anymore.

### 2.7 lwdlg.pas — Dialogs Rerouted to the Browser (549 lines)

Business code is **unchanged**, and LCL dialogs are rerouted on the server to "browser-popped modal boxes":

- Hook points: `InterfaceBase`'s `PromptDialogFunction / InputDialogFunction /
  QuestionDialogFunction`, `Forms.MessageBoxFunction`,
  `RegisterWSComponent(TOpenDialog, ...)` — replaced at runtime, effective as soon as `uses lwapp` is present;
- The server thread really blocks waiting for an answer (180-second timeout), consistent with desktop modal semantics;
- File dialogs: `TOpenDialog.Execute` = the file selected in the browser is **uploaded first** to
  `%TEMP%\lw_uploads\<sid>\pick\`, and `FileName` is the server-side path;
  `TSaveDialog` saves to `<sid>\save\`, and after writing, `SendFile` pushes it to the user (pitfall 17.5);
- When there is no browser session (IDE debugging/unit tests), automatically falls back to the original LCL implementation.

### 2.8 Upload/Download Security (lwupload / lwdownload / lwfileupload)

- `TLWFileUpload` (a TButton descendant): the browser pops a system file picker, XHR with progress,
  and the button text shows the percentage in real time; `Filter/Multiple/MaxSizeKB/TargetFolder` all participate in validation;
- `TLWCamera` (a specialized descendant of `TLWFileUpload`, lwcamera.pas): a photo-capture control that automatically
  chooses a route based on the environment. On mobile it dynamically creates `<input type=file accept=image/* capture=environment|
  user>` to invoke the **system camera app** (`Facing` controls front/rear); the capture approach does not require a secure
  context, so phones work even over LAN http. On the desktop (mouse/trackpad + HTTPS/localhost)
  it instead uses getUserMedia to pop an in-page viewfinder; "Capture" draws the current frame into a canvas, compresses it to a long edge of
  1600px, and converts it to JPEG — desktop browsers ignore capture anyway, and getUserMedia is blocked over http LAN,
  so when neither route works it falls back to selecting an image file; after one failure it sets
  `_camFail` and degrades directly (the getUserMedia catch is already outside the user gesture, so a file picker can no longer be popped).
  Upload/saving/sanitization/size limits all reuse the TLWFileUpload pipeline (lwupload finds controls with
  `C is TLWFileUpload`, which descendants naturally match), and after saving, `AddUploadedFile`
  triggers `OnCapture`. Preview is **browser-local**: `PreviewImage` specifies the name of the target TImage,
  the writer resolves it into a node id for delivery, and after capture the client stuffs it directly into the img with an ObjectURL
  (a `data-lw-photo` marker + `!important` overriding the visibility:hidden binding of TImage) — phone photos are several MB and don't enter the control-tree patch;
- multipart is self-parsed (pitfall 13.1), and filenames are **forcibly sanitized**: strip paths, strip `..`, strip illegal characters,
  and don't trust `Content-Disposition` (pitfall 13.2);
- downloads use a **one-time token**: `SendFile` registers a 30-minute token, and all the browser gets is
  `/lw/download?t=<token>`, which is voided after use (pitfall 13.3).

### 2.9 lwlogin.pas — Login Framework

- `TLWLoginForm` is an ordinary lfm/IDE-designable form;
- `TLWApp.SetLogin(TXxxLoginForm)` enables it in one line; **all events from unauthenticated sessions are rejected**;
- Authentication state is stored at the session level (not process-wide global, pitfall 32.3); the value-sync problem on a wrong password
  is fixed with three gates at the framework layer (pitfall 32.2).

### 2.10 Data Awareness (lwdbgrid / lwdbnav + Native LCL DB Controls)

- `TLWDBGrid`: row positioning, column-header sorting, cell-edit write-back, `PageSize` pagination,
  `ShowFilter` filter bar, `SummaryType(gsSum/gsAvg/gsCount)` summary bar,
  `HeaderGroups` two-level headers (`hg=[{t,a,n}]`, a two-row thead in Alpine / nested columns in Ext);
- `TDBNavigator` crashes on construction under nogui (bitmap primitive chain, pitfall 23) → `LWNewNavigator`
  factories out a safe subclass, and lfm automatically lands on the subclass via `RegisterClassAlias`, while user code writes the native type;
- All 12 data-aware controls have been tested (`docs/DB_AWARE_MATRIX_en.md`); the three hard rules are in the
  README "Database Applications" section (use VARCHAR for SQLite, must explicitly Commit, and don't deliver grid rows while in edit mode).

### 2.11 Peripheral Capabilities

| Unit | Capability |
|---|---|
| `lwchart.pas` | `TLWChart` ctLine/ctBar/ctPie, rendered by the ext-x.x.x charts package, type switchable at runtime |
| `lwreport.pas` | Report engine: printable HTML (A4 / @media print / thead repeated per page) + CSV (BOM+CRLF) + **real XLSX** (OOXML packaged with zipper, zero third-party dependencies) |
| `lwdiff.pas` | Incremental patches (`--patch=1`): diffs the forms arrays of two BuildPayload calls into ops, with client-side self-healing back to the full payload by `tver` (design in `docs/SCALE_en.md` §2) |
| `lwui.pas` | `TLWGauge` / `TLWColorPicker` / session-level overlay |
| `lwweb.pas` | `TLWHTMLFrame` / `TLWPDFFrame` rich-content display |
| `lw-alpine.js` | **Default rendering layer** (Alpine.js 3.14.9): no ext-\<version\> directory needed; Ext JS is an optional layer requiring explicit `--client=ext` (pitfalls 89–97) |
| `lwajax.pas` | `TLWApp.AddAjax(name, handler)` custom endpoints; the context provides Param/Header/JSONBody/Session; unregistered names return 404 and introspectively list all endpoints |
| `lwwebsocket.pas` | `/lw/ws` upgrade (RFC6455): **carries only event requests/responses**; pushes are all delivered via the long-poll cursor (`OnPushCommand` WS direct push retained but disabled by default) |
| `lwhyper.pas` | Dedicated load balancer (equivalent to uniGUI Hyper Server): one process launches N workers (multiple instances of the same exe), automatic restart on crash, HTTP reverse proxy + sid session stickiness, WebSocket TCP-level passthrough, healthz checks; `tools/lwhyper.exe` is the entry point, with its own endpoints `/lw/healthz` (aggregate) and `/lw/hyper/status` (worker details) |
| `lwpanel.pas` + `lwrlog.pas` | GUI server panel (equivalent to uniGUI's standalone server window) and unified logging (see below) |
| `lwconfig.pas` | INI parsing layer: key normalization (case, `-`/`_`/space), sections ignored, UTF-8 BOM, `--config=`. The unit itself reads `Port` / `Theme` / `ExtDir`; `log` / `language` / `patch` / `ssl*` / `client` / `plugin.*` are read from the same INI by `lwapp.pas`'s `ApplyConfigFile` (see 3.2.1). Command line always wins |
| `lwnewproject.pas` + `src/design/lwdesign.lpk` | IDE wizard (New Project has one `lazarusWeb` template; three prompts: (1/3) normal application / service(daemon) mode, (2/3) project tier GUI/nogui determining the .lpi's `LCLWidgetType`, (3/3) template normal/plugin: plugin mode generates a multi-process framework — host exe (`uses upluginproc, upluginauth, ulogin, umain`, with `TLWApp.SetLogin(TLoginForm)` + `LWAuthRegister` → `PlugDiscover` → `PlugRegisterRoutes` → `PlugLaunchAll`) + `common\upluginproc.pas` / `upluginguard.pas` / `upluginauth.pas` / `upluginidentity.pas` + `ulogin.pas` + `plugins\hello\` standalone plugin exe + `build-all.bat/.sh` / `stop-all.bat/.sh` / `README.md`, with host login (admin / analyst / guest, password `123456`, captcha on by default), manifest `roles=` route auth and signed identity headers; the old in-process `lwmodules` / `RegisterAllModules` approach remains only in `demos/plugindemo`; service mode adds `uDaemon.pas` / `uMapper.pas` / `lazarusWeb.ini`, see `SERVICE_NAMING_en.md`) / New Form / component palette, sharing the same template with the `tools/lwnew.exe` command line (`--plugin` / `--service`); lwdesign registers all custom controls into the IDE, so only forms containing them can be opened in the designer; it also registers "Generate lazarusWeb Form Template" in the Tools menu (`lwdsgntplcore` parses the .lfm + `lwdsgntplgen` writes to disk; choose window/flat mode, generating a mode-marked desktop `<form name>.html` and mobile `<form name>.m.html`, see 2.14 and pitfall 154). These are two separate entry points: the New Project wizard creates projects, while the Tools menu generates form templates — don't confuse them |
| `lwconvert.exe` | **LCL → Web converter**: rewrites `.pas` base classes and uses clauses, rewrites `.lpr` startup code, regenerates the `.lpi` as a nogui project, with a support report attached |

### 2.12 GUI Server Panel (lwpanel + lwrlog, equivalent to uniGUI Standalone Server)

- **Unified logging `lwrlog`**: `LWLog/LWLogFmt` + `LWSetLogSink` callback; with no sink, a 200-line fallback buffer,
  and when a sink is attached, a one-time bulk resend; `LWStdOutOpen` uses
  `TTextRec(Output).Handle` to actually test whether stdout is really opened by the RTL (under the GUI subsystem,
  `IsConsole` is unreliable and a bare WriteLn causes I/O 103, pitfall 35.1);
- **Panel `lwpanel`**: menus (File: open browser / copy address / exit; Admin: clear log /
  verbose / About) + a scrolling TMemo log (limited to 4000 lines) + a three-cell status bar (address / session count / duration,
  with a TTimer at 800ms swapping the buffer from a critical section, without Synchronize);
- **accept loop backgrounded**: `TLWServerThread` runs `FServer.Start`, and the main thread runs
  `Application.Run`; on window close, `OnClose` → `Stop` (idempotent) → `WaitFor/Free` (pitfall 35.2);
- Dual builds coexist: `xxx.lpi` (console, --ws=nogui, for tests/CI) and
  `xxx_gui.lpi` (win32 + `-WG`, GUI subsystem, double-click to use).

### 2.13 Concurrency and Thread Model (Summary)

```
fphttpserver (one thread per request)
 ├─ Event request thread: write back value → RTTI triggers business logic → on ShowModal, TEvent.WaitFor blocks here
 ├─ Long-poll push: session queue with seq, each tab fetches by its cursor (WS only carries events, does not push)
 ├─ Sweep thread: expired session cleanup
 ├─ TLWServerThread (GUI build): accept loop
 └─ Panel TTimer (GUI build): main thread periodically swaps the log buffer
```

During a modal for a given session, other requests queue up on the event queue — consistent with desktop application modal semantics.

### 2.14 Adaptation and Form Templates (Built into lw-alpine.js, Zero Server Changes)

Mobile/narrow-window adaptation and both platforms' form templates are all done in the Alpine rendering layer; server-side Pascal
does not participate in device detection:

- **Three detection variables kept separate** (judge "layout mode," not "device," all read live + rAF deduplicated +
  hysteresis, see `MOBILE_en.md` §8): `layout` (enter at ≤834px / exit at ≥1100px / hold in the hysteresis zone),
  `input` (`any-pointer:coarse` + `hover:none`, touch details),
  `capability` (visualViewport / orientation, fallback and not part of detection);
  hard overrides `?layout=` / `sessionStorage['lw-layout']` / `LW.layout.set()`.
  Root markers: `html[data-lw-layout]`, `html[data-lw-input]`;
- **Form templates (same mechanism for window/flat)**: the desktop template `<root>\tpl\<form name>.html`
  (both modes share this one file) and the mobile template `<root>\tpl\<form name>.m.html` are delivered by
  `lwhttp.pas`'s static route `/lw/tpl/<name>` (blocks path traversal with 403,
  missing returns 404, `no-store` so edits take effect immediately), and the server does not parse the content; on the client,
  `lwFetchTpl`/`lwApplyFormTpl` fetch and then read the file header `lw-tpl-mode`:
  `window` → floating-window background layer, `flat` → full-page flat mode (when both coexist, flat takes priority).
  The desktop reads `.html`, and with no template falls back to LCL layout; mobile reads only `.m.html`, and with a template uses the
  mobile template layout, and with no template falls straight back to LCL layout (same as desktop, does not read the desktop `.html`).
  The template is inserted as `.lw-tpl.lw-tpl-backdrop` at the very front of the client area, and the control DOM and
  `S.P[id]` both remain unchanged, still drawn at LFM absolute coordinates (the invariant of pitfall 149 continues to hold).
  Missing template/parse failure → `tplFallback` wholly falls back to the design-time layout. Async responses discard stale ones by
  `fm.tplSeq` sequence number; `lwApplyFlatTpl` hides the title bar/drag corner,
  with width/height taking `max(design value, viewport)` (narrow screens are not squeezed, overflow is panned by `#lw-root`),
  while window mode keeps design-time geometry;
- **One-click template skeleton generation (design-time package, pitfall 154)**: `lwdesign.lpk` registers in the IDE **Tools
  menu** "Generate lazarusWeb Form Template (current unit LFM)" — `lwdsgntplgen`
  hooks the menu/writes to disk; clicking it first pops up "Window mode / Flat mode / Cancel",
  then `lwdsgntplcore` parses the .lfm line by line for top-level visual controls (skipping non-visual controls, sorting visually by
  Top/Left), generating a desktop `<form name>.html` and a mobile `<form name>.m.html`
  into `<project dir>\tpl\` (both desktop modes share the same `.html`):
  the file header contains the `lw-tpl-mode` marker and a list of control design-time coordinates,
  and the body is `<style>` + an empty `<div>` decoration layer, with no placeholders and no changes to control positioning.
  After changing the package source, you must Compile/Install lwdesign in the IDE and restart;
- **No-template fallback = design-time WYSIWYG**: desktop absolute positioning as-is (longstanding behavior);
  mobile forms keep design dimensions (original font size), fixed left-aligned, drag disabled, with overflow scrolled by
  `#lw-root` (`html[data-lw-pan]`); no uniform proportional scaling (on a 390 screen
  the font size drops to only 0.3×, rejected after testing as unreadable, pitfall 150);
- **Device-side form adaptation**: individual controls change form based on `data-lw-layout`/`data-lw-input`,
  e.g. TUpDown with up/down arrows on desktop / −/+ large touch areas on mobile (pitfall 152).

See `MANUAL_en.md` for usage and development guides (the "Mobile" section of the usage part + Part II §16),
and the runnable example `demos/mobile_demo`.

---

## III. Usage Guide

### 3.1 Environment and Build

- FPC 3.3.1 + Lazarus (local installation at `c:\111\fpc`, `c:\111\lazarus`);
- Alpine.js (`src/client/alpine.min.js`, bundled with the repository, default rendering layer, must be kept);
- Ext JS 7.0.0 / x.x.x (**optional**: bring your own `ext-<version>/` and enable with `--client=ext`).

```bat
cd c:\lazarusWeb
build.bat                 :: compile all demos (lazbuild -B --ws=nogui)
build.bat grid            :: compile only demos\grid
build.bat dbaware         :: produces both dbaware.exe (console) and dbaware_gui.exe (GUI)
start-gui.bat             :: double-click to start the GUI server panel
```

On Linux/macOS use `./build.sh`, and the `LAZBUILD` environment variable can override the lazbuild path.
**`-B` is mandatory**: lazbuild does not record `.lfm` files in its dependency table, so when you only change the interface and not the `.pas`,
the old `.o` will continue to be used.

### 3.2 Command-line Parameters

The complete parameter table is maintained in one place in the README's "Quick Start" section (single source of truth, not duplicated here);
new compared with older versions: `--form=` `--client=ext|alpine` `--title=` `--timeout=`
`--patch=1`. The authoritative reference is the `--help` output of the source file `src/core/lwapp.pas`.

### 3.2.1 Configuration File (INI, parsed in `lwapp.pas`)

`TLWApp.Run` reads the INI **before** parsing the command line, so the order is
"built-in defaults → config file → command line", with the command line always winning:

```ini
[lazarusWeb]
Port=8090
Theme=crisp
ExtDir=ext-x.x.x          ; optional: only needed for the Ext rendering layer
;Patch=0
;Client=alpine            ; default; change to ext to use the optional Ext layer
```

- File location: explicitly specified with `--config=`; otherwise `<exe dir>\<exe name>.ini` →
  `<exe dir>\lazarusWeb.ini` → `<current dir>\<exe name>.ini` →
  `<current dir>\lazarusWeb.ini`;
- The parser is very lenient: section names can be omitted (`[lazarusWeb]` / `[server]` / no section), key names ignore
  case and `-`/`_`, values can be quoted, `;`/`#` are comments, and the UTF-8 BOM is automatically skipped;
- `ExtDir` is a **directory**, not a version number: when non-empty, `TLWServer.ExtRootFor` returns it for any
  `/ext/<ver>/...`; pointing to a nonexistent/empty directory → warning + fall back to
  `<root>\ext-<DefaultExt>` (`LWResolveExtDir`);
- Relative paths are expanded first against the exe directory, then the current directory (when started as a service, the cwd is often System32);
- Regression: `tests/t_config.py` (19 items: the three settings take effect, command-line override, empty/bad ExtDir fallback,
  no section name, aliases and quotes, exe directory auto-discovery, default 8090).

### 3.3 Writing Your Own Web Program

```pascal
program myapp;
uses Interfaces, Forms, lwapp, uMain;
begin
  Application.Initialize;
  TLWApp.Register(TMainForm);   // removing the T from the class name gives the form name in the browser
  TLWApp.SetLogin(TLoginForm);  // optional: enable the login framework
  TLWApp.Run;
end.
```

The only line to change in the form unit:

```pascal
uses ..., lwform;
TMainForm = class(TLWForm)   // originally class(TForm)
```

You can also use the IDE wizard (install `src/design/lwdesign.lpk`, first run `tools\install_design.bat`)
or the command line `tools\lwnew.exe --name=DemoApp --dir=C:\work\DemoApp --units=C:\lazarusWeb\src\core`.

### 3.4 Quick Reference for Common Capabilities

| Requirement | How to do it |
|---|---|
| Synchronous modal | Write `f.ShowModal = mrOk` as-is; in the browser it really waits for the user to click |
| Message/input boxes | Write `ShowMessage / MessageDlg / InputQuery / QuestionDlg / MessageBox` as-is |
| File upload | Place `TLWFileUpload` at design time, and write `OnUpload(Sender, AFileName)` |
| Photo capture | Place `TLWCamera` at design time, `PreviewImage='imgPhoto'` (local echo), and write `OnCapture(Sender, AFileName)`; mobile uses the system camera (works over http), desktop uses an in-page viewfinder under HTTPS/localhost |
| File download | `SendFile('报表.xlsx')` or `SendText(csv.Text, '清单.csv', True)` |
| Report export | `TLWReport`: three outputs `SaveHTML / SaveCSV / SaveXLSX` |
| Charts | `TLWChart`: ctLine / ctBar / ctPie, switchable at runtime |
| Custom AJAX | `TLWApp.AddAjax('items/price', handler)`, front end `fetch('/lw/ajax/items/price')` |
| Toast | `Self.ShowToast('已保存')` |
| DB grid pagination | `TLWDBGrid.PageSize := 20; ShowFilter := True; SummaryType := gsSum;` |
| Confirm/switch rendering layer | Alpine.js by default (built-in, no configuration needed); optional Ext requires bringing your own `ext-<version>/` and `--client=ext`; the `Client:` line in the startup banner shows the layer actually in effect |
| Full-page flat layout for phone/narrow window | Write `<root>\tpl\<form name>.html` with file header `lw-tpl-mode:flat`; controls still use design-time absolute coordinates, and the page itself scrolls; see `MANUAL_en.md` Part II §16 |
| Window-mode background decoration | The same `<form name>.html`, with file header `lw-tpl-mode:window`; form geometry stays at design time, and the template serves only as a background layer; see `MANUAL_en.md` Part II §16 |
| Quickly get a template skeleton from an existing form | In the IDE Tools menu, "Generate lazarusWeb Form Template (current unit LFM)" (lwdesign design-time package); after choosing a mode, generates a `<form name>.html` from the .lfm, then refine per §16.2; see `MANUAL_en.md` §16.0 |

### 3.5 Deployment

- **Self-contained deployment (default Alpine layer)**: exe + `src/client/alpine.min.js` (~44KB)
  + `lw-alpine.js` (~205KB) + `lw-alpine.css` (~47KB); no `ext-*` directory needed.
  All three Alpine files are required (missing js falls back to probing Ext, missing css leaves the page unstyled),
  and the startup banner prints the `Client` actually adopted;
  **Optional Ext layer**: additionally add `ext-x.x.x/` (~75MB) + `lw.js` + `lw.css`,
  and explicitly enable with `--client=ext`;
- **HTTPS**: FPC comes with `TFPHttpServer.UseSSL`; adding `--ssl` to the business exe or lwhyper
  terminates TLS on the same port (self-signed certificate with zero configuration, OpenSSL DLL shipped with the package, see pitfall 160);
  TLS can also be terminated by an nginx/Caddy reverse proxy (ready-made configs `deploy/nginx.conf`, `deploy/Caddyfile`,
  and add `--trust-proxy` after the reverse proxy);
  nginx's `/lw/ws` location must carry `Upgrade/Connection` headers, otherwise WS silently degrades to long polling;
- **Clustering**: two approaches. ① **lwhyper dedicated load balancer** (equivalent to uniGUI Hyper Server):
  `lwhyper.exe --port=8080 --workers=3 --exe=<business exe>`, with one process handling
  worker supervision + reverse proxy + sid stickiness + WS passthrough, so nginx is no longer needed for HTTP scenarios;
  ② nginx/Caddy reverse proxy + sticky sessions (nginx `ip_hash` / Caddy
  `lb_policy ip_hash`). In both, sessions live in process memory (external Redis not implemented);
  health checks hit `/lw/healthz`; after an instance fails over, the browser receives a 410 and automatically creates a new session and returns to the login page;
  for capacity estimation (single process ≈ 155 events/sec, scale ≈ N × 155), the incremental patch protocol, and the phased
  plan, see `docs/SCALE_en.md`;
- **Service mode**: GUI build + `--nogui` (no window) + `--log=path` (logs written to disk).

### 3.6 Regression Tests

`python tests/t_xxx.py` (HTTP level, start the service first; `run_with_server.py` can start/stop automatically):

| Script | Coverage |
|---|---|
| t_dbaware2 / t_closewin / t_multitab / cdp_multitab | full DB suite / close-window-return-to-login / multiple tabs |
| t_dbaware(134) / t_db(35) | data-aware write-back to DB / SQLite CRUD |
| t_dialog(36) / t_files(28) / t_controls(26) | dialogs / upload-download / controls |
| t_ws(8) / t_login(15) / t_attach(42) | WebSocket / login / attachment |

The current full regression is **hundreds of items all green** (snapshots at various stages were 385–472 items; the exact count is per the most recent
full run of `tests/run_with_server.py`). The CDP scripts drive headless Edge for real-browser verification.

### 3.7 Known Limitations

- Modal timeout is 180 seconds; only one dialog at a time per session;
- `TOpenDialog` cannot browse the server disk (upload only); `TSplitter` supports dragging (the displacement is sent back → the server calls `SetSplitterPosition` to rearrange neighbors by Align, pitfall 186);
  `TUpDown/TProgressBar/TTrackBar` write back `Position` on the browser side; unsupported controls are shown as gray placeholder boxes in the browser;
- High DPI is handled as 96 DPI on the virtual display, and lfms designed at 125%/150% are automatically scaled back to 96;
- After a port is force-killed, orphan sockets may remain (`LISTENING PID 0`); switching ports is the easiest fix;
- Direct PDF output is temporarily replaced by the browser's "Save as PDF" (fcl-pdf's ToUnicode is not yet stable);
- External Redis for sessions is not implemented (clustering relies on sticky sessions).

### 3.8 Pitfall Records

As of 2026-11-28, all 212 pitfalls are recorded in `docs/NOTES.md`
(nogui infrastructure → fpjson/encoding → SQLite/WAL → design-time packages → multipart security →
dialog hooks → WebSocket → multi-tab cursors → GUI panel → lfm-ification refactoring → performance profiling →
load-test troubleshooting), the most valuable asset of this framework — each pitfall comes with root-cause analysis and verification methods.
Note that pitfalls accumulate over time: pitfall 23 (TDBNavigator's RegisterClassAlias) was overturned by pitfalls 29/41,
and pitfall 66 (TLabeledEdit label not fixed) was fixed by pitfall 69 — the latest pitfall takes precedence.
