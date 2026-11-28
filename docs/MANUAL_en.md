# lazarusWeb User Manual

> Version baseline: LW_VERSION 0.9.6 (`src/core/lwbase.pas`), updated 2026-11-17.
> Divided into two parts: the **Usage Part** (running demos, writing programs,
> deployment, troubleshooting) and the **Development Part** (reading code,
> debugging, extending, testing). Details are governed by the respective topical
> documents; this manual is responsible for threading them together into one path.

---

# Part I  Usage Part

## 1. What Is This

lazarusWeb lets an ordinary Lazarus/FPC desktop program run in the browser **without changing its architecture**:

- The business form's base class is changed from `TForm` to `TLWForm` (a real TForm descendant); `.lfm`, events, and business code are kept as-is;
- It compiles into a `--ws=nogui` headless service (virtual display patch `lwws.pas`);
- On the server side each browser tab holds a real LCL control tree. Events come back through HTTP/WebSocket and are dispatched by RTTI to the real control events; `ShowModal`/`ShowMessage`/`TOpenDialog` are automatically rerouted to browser modal dialogs, and the server really blocks and waits;
- On the browser side, rendering and id-based reconciliation of incremental updates are performed by `lw-alpine.js` (Alpine.js 3.14.9, **default**) or `lw.js` (Ext JS x.x.x, optional); with `--patch=1`, an event returns only a 2~4KB delta.

It is benchmarked against the commercial product uniGUI. See `docs/ARCHITECTURE_en.md` for a technical overview.

## 2. Environment and Build

Toolchain: FPC 3.3.1 + Lazarus (on this machine at `c:\111\fpc` and `c:\111\lazarus`).
`build.bat` auto-detects lazbuild (environment variable `LAZBUILD` → Program Files →
`C:\111\lazarus`).

```
build.bat              :: Build all 10 demos (lazbuild -B --ws=nogui)
build.bat grid         :: Build only demos\grid (db→dbdemo, files→filedemo are recognized automatically)
```

Key points:

- **`-B` is mandatory**: lazbuild does not track `.lfm` dependencies; if you change a form and rebuild without `-B`, it silently links the old `.o` (this is the most common "changed but no effect" case);
- **Close any running exe before compiling**, otherwise you get "Can't create object file (error 5)";
- `build.bat` must remain ASCII + CRLF (cmd.exe hangs when parsing UTF-8 Chinese comments);
- Artifacts land in each demo's own directory (e.g. `demos\db\dbdemo.exe`);
- On Linux/macOS use `build.sh`.

## 3. Run Your First Demo

```
demos\multi\multi.exe --port=8090        :: Menus / multi-tab / synchronous modal
demos\db\dbdemo.exe --port=8095          :: SQLite CRUD (requires demos\db\sqlite3.dll)
demos\files\filedemo.exe --port=8096     :: Upload / download
demos\dbaware\dbaware.exe --port=8110    :: The full set of DB-aware controls
start-demo.bat                           :: Run dbdemo in the foreground (8092 by default, Ctrl+C to stop)
start-gui.bat                            :: GUI version dbaware_gui.exe (pops up the server panel)
```

Open `http://127.0.0.1:8090/` in a browser.

Demo overview (all executable entry points are under `demos/`; the framework itself is a library, not an exe):

| demo | What it demonstrates |
|---|---|
| hello | Minimal example (one form, one button) |
| grid | Grid/table |
| multi | Menus / multiple tabs / synchronous modal round-trip |
| db | SQLite CRUD (project name dbdemo) |
| files | Upload and download |
| dbaware | The full DB-aware set (dbaware.lpi console version + dbaware_gui.lpi GUI version) |
| dialogs | Dialog rerouting |
| controls | Control gallery |
| login | Login/permission framework |
| gallery | Full-featured gallery (stress-test baseline, shipped with lwperf/lwdump) |
| audit | LFM chain audit demo (auditdemo) |
| mobile_demo | Mobile comparison example (template-less forms fall back to pan mode; the old placeholder templates in `tpl/` are a historical mechanism — in new versions they serve only as a background layer and do not rearrange controls; see 16.2 for the new approach) |

## 4. Write Your Own Program

Minimal changes (three steps):

```pascal
// 1) Change the form base class in one line
TMainForm = class(TLWForm)          // was class(TForm)

// 2) Project file startup code
Application.Initialize;
TLWApp.Register(TMainForm);         // Register the form (multiple allowed, --form= selects the default)
TLWApp.Run;                         // Start the HTTP service

// 3) Add -dLCLnogui to the project compile options (--ws=nogui)
```

- Dialogs need no changes: `ShowMessage` / `MessageDlg` / `InputQuery` / `TOpenDialog` are automatically rerouted to the browser by `lwdlg.pas`;
- Database controls bind directly to `TDataSource`, behaving the same as on the desktop; for the three hard rules of SQLite see the "Database Applications" section of README (VARCHAR columns, explicit Commit, do not send grid rows while in edit mode);
- Custom AJAX endpoint: `TLWApp.AddAjax(name, handler)` (corresponding to uniGUI's AddAjaxProcedure); third-party JS can directly fetch `/lw/ajax/<name>`;
- Login: `TLWApp.SetLogin(TXxxLoginForm)` enables it in one line; see `demos/login/`; for the graphical CAPTCHA on the login form see "Graphical CAPTCHA on the Login Form (TLWCaptcha)" below;
- Charts `TLWChart`, reports `lwreport` (HTML/CSV/XLSX), rich content `TLWHTMLFrame` / `TLWPDFFrame`, gauge `TLWGauge`, and color picker `TLWColorPicker` are all controls built into the framework;
- Use **TFPTimer** for timers (you must set `UseTimerThread=True`) — TTimer is unavailable under nogui.
- There are two plugin flavors (**the wizard's "plugin mode" generates the second one**):
  - **Legacy same-process flavor (kept for reference)**: put pages and AJAX in `plugins/umod_*.pas`, declare `procedure RegisterModule;` in the unit, run `python tools/lwplugins.py` to generate a registration summary, and have the main program call only `RegisterAllModules`; see `demos/plugindemo`.
  - **Current multi-process plugin mode (recommended)**: the host and each plugin are separate exes; manifest scanning, process launch, hot reload, role checks and identity headers are all generated for you. See `demos/pluginsDemo/README.md` and the flavor comparison at the top of `docs/PLUGIN_GUIDE_en.md`.
  Design form UIs with **`.lfm`** as usual (write `{$R *.lfm}` in the unit; put fields and event methods in the default section of the class declaration; `.lpi` needs no separate resource registration); if you prefer not to use `.lfm`, you can also build a form purely in code. **See `docs/PLUGIN_GUIDE_en.md` for the steps** (both flavors, `.lfm` caveats and common problems); for principles and a comparison see `docs/PLUGIN_FEASIBILITY_en.md`.

> **Security / SQL injection**: The framework layer does not touch SQL and has no SQL endpoint; the browser only sends control values. Injection risk lies in business code — any value coming from a control/AJAX/URL must go through `ParamByName` before entering SQL (use a whitelist or numeric conversion for `ORDER BY`/`LIMIT`). For the complete trust boundary, demo examples, and a self-check list, see `docs/SECURITY_en.md`.

One-click migration of an existing project:

```
tools\lwconvert.exe <project directory> --convert <output directory>
tools\lwconvert_gui.exe                :: GUI version: select directory → analyze/convert → view report
```

What it rewrites: `.pas` base classes and uses clauses, `.lpr` startup code, `.lpi` regenerated as a nogui project, plus a control-support report. There is also a wizard in the IDE: the design-time package `lwdesign` (one template in New Project — it asks three questions: application mode / project type / project template — plus New Form and the component palette).

### Create a New Project with the IDE Wizard (From Scratch)

**Prerequisite: install the four packages into the IDE in order** (only once; redo after upgrading to a new package version)

The four packages have a dependency chain, and the **order cannot be reversed**: `lwcore` → `lwserver` → `lwvst` → `lwdesign` (`lwserver` and `lwvst` both depend on `lwcore`, and `lwdesign`, the design-time package, depends on the first three plus IDEIntf). Skipping a step will cause `Can't find unit lwcore / lwserver / lwvst` when you Install `lwdesign`.

| Order | Package | Type | IDE action |
|---|---|---|---|
| 1 | `src\lwcore.lpk` | RunAndDesignTime | Only **Compile**, do not Install |
| 2 | `src\lwserver.lpk` | RunAndDesignTime | Only **Compile**, do not Install |
| 3 | `src\lwvst.lpk` | RunAndDesignTime | Only **Compile**, do not Install (GUI chain: `TLWDBVirtualTreeView`, requires real GDI; compile with the target IDE's native widgetset, not `--ws=nogui`) |
| 4 | `src\design\lwdesign.lpk` | DesignTime | **Compile → Use → Install** → rebuild → restart |

0. First register the four packages from the command line (otherwise New Project reports "package not found"):
   `tools\install_design.bat` (equivalently `lazbuild --add-package-link` for `src\lwcore.lpk`, `src\lwserver.lpk`, `src\lwvst.lpk` and `src\design\lwdesign.lpk`). `--add-package-link` only registers without installing, which is normal.
1. Open Lazarus and, **in the order of the table above**, open each package with `Package → Open Package File → <package>.lpk`:
   for the first three click only **Compile**; for the fourth click **Compile → Use → Install**, choose "Yes" in the dialog asking whether to rebuild the IDE, and after the rebuild finishes **restart Lazarus**.
2. Note: do not Compile `lwserver.lpk` in the IDE (the nogui units are not on the IDE search path, giving `Can't find unit noguiint`; see pitfall 15 in `NOTES.md`); leave that to the command-line `lazbuild`. For the `Descriptor.Name empty` dialog when installing the design-time package, see pitfall 16.

Only after installation will a template named **lazarusWeb** appear under **File → New → Project** (selecting it pops up the three dialogs below). If it is not installed (or an old version is installed), you will not see it in the New dialog. The Tools menu item "**Generate lazarusWeb Form Template (Current Unit LFM)**" also comes from the `lwdesign` package — this is a **different feature** (generating an HTML template from the current form's .lfm, see 16.0) and has nothing to do with the New Project wizard. After changing a package's source you must recompile → Install → restart the IDE, otherwise the menu still runs the old logic.

**1. Select the template — three selection dialogs pop up in sequence**

After selecting **lazarusWeb**, three dialogs appear one after the other (cancelling any of them exits without touching the current project):

The first dialog (1/3), the application mode:

| Option | Project generated |
|---|---|
| **Normal application mode** | An ordinary lazarusWeb program, accessed from a browser (the historical behaviour, unchanged) |
| **Service (daemon) mode** | Additionally generates the `uDaemon.pas` / `uMapper.pas` / `lazarusWeb.ini` host layer, and the `.lpr` gets a `DaemonApp` branch: **the same exe can run in the foreground and also be registered as a Windows service with `--install`** (see `WINDOWS_SERVICE.md`) |

The second dialog (2/3), the project type tier:

| Option | Tier | Program produced |
|---|---|---|
| **lazarusWeb project** | `$APPTYPE GUI`, default widgetset | Runs directly with F9 in the IDE, with **no** black console window (for debugging) |
| **lazarusWeb project(nogui)** | `$APPTYPE CONSOLE` + `LCLWidgetType=nogui` | Pure console service, with only a **black terminal** (for deployment) |

The third dialog (3/3), the project template:

| Option | `.lpr` generated |
|---|---|
| **Normal mode** | Normal project: `uses lwapp, umain`, `TLWApp.Register(TMainForm)` |
| **Plugin mode** | **Multi-process plugin framework**: host project (`uses upluginproc, upluginauth, ulogin, umain`; startup calls `TLWApp.SetLogin(TLoginForm)` + `LWAuthRegister` → `PlugDiscover` → `PlugRegisterRoutes` → `PlugLaunchAll`, with a sidebar menu + `TPageControl` plugin workbench as the main form) + `common\upluginproc.pas` + `common\upluginguard.pas` (startup guard: token + parent-process check, so a plugin exe cannot run on its own) + `common\upluginauth.pas` (role checks, menu filtering, 403 on `/p/`, identity signing) + `common\upluginidentity.pas` (plugin-side signature verification to read the "current user") + `ulogin.pas` (graphic captcha on by default) + `plugins\hello\` sample plugin project (a standalone exe) + `build-all.bat` / `stop-all.bat` (Windows) and `build-all.sh` / `stop-all.sh` (Linux/macOS, LF line endings) + `README.md`. On Linux the manifest still says `exe=xxx.exe`; `upluginproc` automatically falls back to the extensionless artifact and sets the execute bit on the `.run\` copy. The host `.lpi`'s `OtherUnitFiles` points at `common` automatically; the plugin manifest root is `<host exe dir>\plugins`. Demo accounts `admin` / `analyst` / `guest`, password `123456`; a manifest's `roles=admin,analyst` controls access. If you do not need login, remove the `SetLogin` / `LWAuthRegister` lines from the `.lpr`; removing only the menu filter but not the route guard leaves unauthorized access open |

After all three dialogs are answered, **nothing is written to disk**: the project is "virtual" at this moment, with the source of `.lpr` / `umain.pas` / `.lfm` (plus `uDaemon.pas` / `uMapper.pas` / `lazarusWeb.ini` in service mode) all in memory, and the title bar reads `LWApp1 (*lpi)`. In plugin mode the whole `common\` / `plugins\` tree is **not** part of the host project's units — it is written by the save hook after the project files are saved (existing files are not overwritten). This is completely consistent with the flow of Lazarus's own templates.

> In service mode those three extra files are **already complete and correct before anything is written to disk** — they do not depend on a save hook patching them afterwards. `uMapper.pas` builds its `DaemonDefs` in code and therefore needs **no `.lfm` resource** (see pitfall 195 in `NOTES.md`).

**2. Ctrl+S is what writes to disk**

What pops up is Lazarus's standard "Save Project" dialog:

- The **directory** defaults to the "directory for building and testing projects" in the IDE options; if you saved somewhere else last time, that directory is shown here (e.g. `C:\3`) — just change it to the directory you want in the dialog, and after changing it once it becomes the default from then on;
- Do not use `LWApp` as the **project name** — it has the same name as the framework unit `lwapp.pas`, so compilation will inevitably report `Duplicate identifier "LWAPP"`. The default `LWApp1` is safe; if you want to change it, use something like `LWApp2` / `MyApp`.

**3. Result on disk**

```
<directory>\LWApp1.lpr  LWApp1.lpi  umain.pas  umain.lfm
       build.bat   build.sh    favicon.ico
       lw\        ← Front-end resources (lw.js/lw.css/alpine.min.js…)
```

Service (daemon) mode writes three more files (also in the same Ctrl+S save; the wizard
opens a tab for each of them so you can tweak the service name / port right away):

```
       uDaemon.pas    ← daemon class + worker thread (RunService / Halt on non-SCM stop)
       uMapper.pas    ← TDaemonMapper descendant, stAuto; the service name follows the project name entered at Ctrl+S (rewritten before the files are written) — see SERVICE_NAMING_en.md
       lazarusWeb.ini ← port= / log= / client= (fixed name, found automatically at runtime)
```

`build.bat` / `build.sh`, the `.lpi` macros of the nogui tier, `favicon.ico`, and the front-end resources in `lw\` cannot be produced by the IDE's project model; the wizard fills them in **about 1 second after saving** (at runtime static resources are looked up as `exe\lw\<file>`, so they are copied to `lw\` under the project directory).

`favicon.ico` goes in the **project root directory** (not `lw\`): the server fetches the icon in the order `<root>\favicon.ico` → `<exe directory>\favicon.ico`, and the exe is right in the project directory. Without it the browser tab shows a blank icon (`/favicon.ico` returns 404 directly). To use your own icon, just overwrite `favicon.ico` in the project directory — once it exists, the wizard will not touch it again.

**4. nogui tier: one extra "reload" step, or F9 uses the wrong widgetset**

About 1 second after saving, this pops up:

> **nogui tier: takes effect after reloading the project** — LCLWidgetType=nogui has been written to the project…

Click **"Yes"** and the IDE immediately re-reads the project according to the new `.lpi`, after which F9 gives a windowless console service. Clicking "No" also works: the `.lpi` is already nogui, so just build with `build.bat` in the project directory; it takes effect automatically the next time you open the project.

> **Note: pressing F9 within 1 second of saving still uses the win32 widgetset** — the macro has only just been written into the `.lpi` file, while the project options in the IDE's memory have not been re-read, so the build will still pop up the server panel window. Wait for that confirmation dialog to appear, click "Yes", and then F9 will be correct.

**5. When something goes wrong**

- **"File not found …\umain.pas" pops up**: only half the files remain in the project directory (`.lpi`/`.lpr` present, `umain.pas` missing). This was left behind by early versions reloading the project inside the save transaction (see pitfall 172 in `NOTES.md`); the current version shows no dialog and does not reload during saving, so it will not recur. Fix: **Project → Close Project**, then create a new one.
- **F9 still pops up the panel window**: confirm that you clicked "Yes" on the "reload" dialog, and that the project is not one you renamed and then reopened with the old `.lpi`; you can also compare directly using `build.bat` in the project directory (in the nogui tier it is `lazbuild -B --ws=nogui <project name>.lpi`; the GUI tier omits `--ws`).
- **Check the log**: `%TEMP%\lazarusweb-wizard.log` records one line each time it fills something in — the `.lpi` path, the tier (`headless=gui|nogui`), whether the macro was inserted (`widgetset: inserted=True`), how many client files were copied, and whether it was waiting for saving to finish (`保存还没写完，等下一轮`). To see whether the fill-in happened, this file is the most direct way.

For non-IDE scenarios (CI, scripted project generation):

```
tools\lwnew.exe --name=CliDemo --dir=D:\proj\CliDemo --gui
```

The same skeleton, which likewise copies `src/client` to `lw\` under the project.

### Mobile: Phones / Narrow-Window Adaptation (Zero Changes to Business Code)

The Alpine rendering layer (default) has built-in mobile adaptation; the decision is made entirely on the browser side, with no server involvement:

- **Automatic detection**: a viewport width ≤834px enters the mobile layout, ≥1100px exits it, and 835~1099 is a hysteresis zone that keeps the current state (dragging the window or the soft keyboard popping in and out will not cause flapping); phones, tablets, and narrow desktop windows all enter automatically. Touch details (input font size ≥16px, removing the double-tap zoom delay) are decided independently by pointer capability, regardless of window width;
- **Forms with no template (both ends consistent: what you see at design time is what you get)**: on mobile they are rendered at their design size as-is (**font size is not shrunk**), and anything beyond the screen is viewed by page scrolling/panning — usable, but not a layout optimized for small screens; on desktop they are absolutely positioned as-is (historical behavior, completely unchanged);
- **Forms with a template**: the template is only a background/decoration layer; controls are always rendered at the LFM's absolute coordinates, and events and incremental patches are unchanged; the `lw-tpl-mode` in the header of `<form name>.html` decides between floating-window and full-page flat mode (flat takes priority). Neither mode rearranges controls;
- **Manual switching** (for demos / troubleshooting): add `?layout=mobile` or `?layout=desktop` to the URL; in the console `LW.layout.set('mobile'|'desktop'|'auto')`, `LW.layout.get()`; the choice is stored in `sessionStorage['lw-layout']` and affects only the current tab;
- For how to write templates and complete examples, see Part II, "16. Form Template Development Guide (Window + Flat)"; one-click generation uses the IDE Tools menu (choose window/flat mode; desktop writes `<form name>.html`, mobile writes `<form name>.m.html`), and template changes take effect on refresh with no recompilation.

### Taking Photos: TLWCamera (Invoke the System Camera on a Phone, In-Page Viewfinding on Desktop)

Drag `TLWCamera` (a specialized descendant of `TLWFileUpload`) from the component palette onto the form and write one event:

```pascal
procedure TMainForm.camPhotoCapture(Sender: TObject; const AFileName: string);
begin
  // AFileName is the full path on the server (%TEMP%\lw_uploads\<session>\<control>\xxx.jpg),
  // just process it with TFileStream / store it in the database later; the preview is not done on the server
end;
```

After the capture button is pressed, the browser automatically chooses a route based on the environment (**the same code, with no branching needed**):

| Environment | Behavior | Prerequisite |
| --- | --- | --- |
| Phone / tablet | `<input capture>` invokes the **system camera app** (rear camera by default, `Facing := cfFront` for front); after capture it is sent via `/lw/api/upload` back to the server to be saved to disk and trigger `OnCapture` | None; works over LAN http |
| Desktop + HTTPS/localhost | **In-page viewfinder overlay** (getUserMedia): live video + "Capture / Cancel / Choose Image"; the captured frame is compressed to a long edge of 1600px, converted to JPEG, and sent through the same upload channel | Requires a secure context |
| Desktop + LAN http | Degrades to a "choose an image file" dialog (browsers forbid http pages from calling the camera — a hard limit) | — |

- Preview echo: fill the Name of a `TImage` on the form into `TLWCamera.PreviewImage` (e.g. `imgPhoto`); after capture the browser displays it **locally and immediately** (not through a server patch — a phone photo is several MB, and stuffing it into the control tree as base64 would make every subsequent incremental patch run for nothing); the server-side `TImage.Picture` is always empty; if you want a server-side thumbnail or database storage, process the file yourself;
- The size limit `MaxSizeKB` (KB, 0 = unlimited), the save directory `TargetFolder` (blank = the session upload directory) have the same semantics as the upload button; `UploadedFiles`/`LastFileName` can be queried for history;
- Both `OnUpload` and `OnCapture` fire; hooking one of them in your business code is enough;
- Runnable example: `demos/mobile_demo` (capture + local preview + logging, with separate desktop/mobile templates, a complete experience on a phone); regression `tests/cdp_camera.py`.

### Graphical CAPTCHA on the Login Form (TLWCaptcha)

The CAPTCHA on TLWLoginForm is enabled by "just dropping a control onto it" — not a single line of code:

1. In the **lazarusWeb** page of the component palette, drag a `TLWCaptcha` onto the login form (it is a visual control, sized = image size, 110×34 by default);
2. Put another `TEdit` as the input box, using the conventional name **`edCode`**. It need not follow the convention: the base class first looks for an edit box whose name contains `code` / `captcha` / `vcode`, and finally falls back to "the first TEdit other than the username and password ones";
3. Done. `TLWLoginForm.TryLogin` **verifies the CAPTCHA first, then the username/password** (the order cannot be reversed: checking the account first would open a back door for brute-force enumeration); a wrong code pushes a Toast and automatically swaps in a new image.

Details:

- Comparison ignores case and leading/trailing spaces; **each code may be tried only once** (it is invalidated immediately after comparison, and a failure automatically swaps the image), so the same image cannot be guessed repeatedly;
- "Click the image to get a new one" is a pure front-end action (append `&r=<timestamp>` after `src`), which neither occupies the session execution lock nor waits for a round trip; when the server sees `r` it regenerates the answer. A server-initiated image swap (login failure, or business code calling `RefreshCaptcha`) uses the version number `&v=`; only when `src` changes in the patch will the browser re-fetch;
- The image is a PNG drawn on the fly by the server using a built-in 5×7 dot-matrix font and FPImage: zero font dependency, zero widgetset dependency, so it works in the nogui tier too;
- Dark themes do not redraw a second image; the client uses `filter: invert(...)` to invert it, so switching themes costs no extra request;
- To opt out: simply do not place a `TLWCaptcha` on the form (**old projects are completely unaffected** — the CAPTCHA is verified only when the control is actually present on the form), or set `RequireCaptcha` to `False`;
- To tune: `Left/Top/Width/Height` set the position and size, `CaptchaLength` (2..8, default 4) sets the character count; business code can call `RefreshCaptcha` to swap the image proactively (e.g. forcing a new code after an account is locked);
- Troubleshooting: start with the environment variable `LW_CAPTCHA_DEBUG=1`, and the server prints `[lw] captcha <token> = <answer>` to stderr — used to tell whether the problem is "wrong code" or "wrong image" (do not enable in production).

### The Login Form Works Out of the Box: CAPTCHA Included on Creation

Both ways of creating a new form come with a CAPTCHA — no need to place controls or write verification code yourself:

- **IDE File → New → `lazarusWeb Login form`**: the template .lfm already has `lblCode` / `captcha1` / `edCode` placed (plus two buttons wired to the base class's `DoLogin` / `DoReset`); after modifying the design-time package remember to recompile once in the IDE;
- **Create a normal form and change its base class to `TLWLoginForm` (or use `SetLogin(TLWLoginForm)` with the base class directly)**: when the form has no controls at all, the base class automatically builds the username / password / CAPTCHA / two buttons in `AfterConstruction` at the same set of coordinates (`AutoBuildUI`, on by default). You cannot see these controls at design time, but they are there at runtime; once you have placed any control yourself (in the lfm or created in `FormCreate`), it stops interfering.

### When the Login Session Expires

The sid is stored in **sessionStorage** (`lw.sid`), not localStorage and not a cookie:

- Refreshing the page — you are still in the same tab, so a refresh does not log you out;
- **Closing the tab — sessionStorage is destroyed along with the tab, so you must log in again the next time you open it** ("closing the tab logs you out", the same mental model as a desktop program where "closing the window = exiting");
- Closing the browser — of course that also logs you out;
- **The browser's "restore the last opened pages on startup" also logs you out**: restoring the session brings back sessionStorage together with the sid, so the client leaves a tombstone at `pagehide` (`lw.bye` = the unload time). If unload to the next load is only tens of milliseconds apart, it counts as a "refresh" and login is preserved; if more than 3 seconds elapsed before returning (= the window was closed in between), the old sid is not accepted and you must log in again. The criterion uses `performance.timeOrigin` (the start time of this navigation) minus the tombstone time; how long the page itself takes to load is not counted, so a slow server will not misclassify a refresh as a window close. The threshold `BYE_GRACE_MS = 3000` is written in `lw-alpine.js` / `lw.js`;
- Each tab has its own session: opening a second tab in the same browser is a **new session** and does not automatically share the previous page's login identity (to share, explicitly open with the same sid; the framework's `/lw/api/attach` is still there, see `docs/ARCHITECTURE_en.md` 2.3);
- No port number in the name: sessionStorage is isolated by origin (protocol + host + port), so running multiple demos on one machine naturally does not interfere.

For "Remember me" (stay logged in across tabs and browser restarts), set `localStorage['lw.persist'] = '1'` in the page; to force a new session when debugging, add `?fresh=1` to the URL. Session cookies left in the browser by old versions (`lw_sid_<port>`) are quietly cleared at startup and do not affect the new semantics.

### Status Bar (TStatusBar): Panel Widths/Alignment Follow the LFM

Drag a `TStatusBar` onto the form (default `Align=alBottom`), set `Panels` in the IDE (`Text` / `Width` / `Alignment` / `Bevel` for each panel), and the browser side shows a panel bar structurally identical to the desktop one:

- **Height** is taken from `TStatusBar.Height`, scaled by the form's `DesignTimePPI / current PPI` (designed at 144PPI, running at 96PPI → 34 becomes 23), using the same ruler as the child control coordinates;
- **Panel widths** use `Panels[i].Width`, and **the last panel extends to the right edge** (LCL's `SB_SETPARTS` rule); there is a 1px separator between panels, absent for panels with `Bevel=pbNone`;
- **Alignment** `taLeftJustify / taRightJustify / taCenter` map respectively to `text-align`; text too long for the panel is clipped (`ellipsis`), never expanding the panel;
- Status bar width = client area width: the form's outer frame is drawn with an inset shadow and does not consume the box model (otherwise the client area is 2px narrower than the LFM's `Width`, and `Align=alNone` containers overflow);
- When `SimplePanel=True`, only `SimpleText` is shown (same as LCL);
- Text is written by business code: `stbMain.Panels[0].Text := '就绪';` — once the server changes it, the next patch delivers the new text to the browser (the second panel of `demos/multi` shows the row count).

To customize the style, change the CSS variables or the two rules `.lw-statusbar` / `.lw-status-item`; the server is unaffected.

### Multi-Level Headers (TLWDBGrid.HeaderGroups)

LCL's `TDBGrid` has only one header row; for "multi-level headers" use the framework's extension `TLWDBGrid` (write the class name `TLWDBGrid` in the lfm — FPC's GetClass recognizes only the exact class name):

```pascal
uses lwdbgrid;

with grdMain.HeaderGroups do
begin
  Add('基本信息|0-2');     // Title|start-end: start/end are "visible column" indices (0-based, end inclusive)
  Add('价格与库存|3-5');
end;
// Columns not in any group span the two rows themselves (the upper and lower rows merge into one cell)
```

- Hidden columns (`Visible=False`) do not consume a column number; groups are counted from the left among the visible columns;
- Clicking a group header produces no `OnTitleClick` (a cross-column header has no unique column); leaf headers post back normally;
- The two header rows stick to the top of the grid as a whole and do not come apart when scrolling;
- See `demos/db` and `demos/gallery` for a demo (two tabs: data-aware / large-table pagination).

### `&` in Caption (Accelerator Keys / Mnemonics)

As in LCL, `Caption := '确定(&O)'` displays on a web page as **确定(O)** with `O` underlined, and pressing `Alt+O` is equivalent to clicking that button — the `&` is not shown. The rules are **per control**:

- Parsed: TLabel, TStaticText, the button family, TCheckBox/TRadioButton, TRadioGroup/TCheckGroup (captions and items), TGroupBox, TPageControl/TTabControl tabs, TMenuItem;
- Not parsed: **TPanel.Caption** (`TCustomPanel.ShowAccelChar` defaults to False), any control with an explicit `ShowAccelChar := False`, the `Items` of TListBox/TComboBox/TCheckListBox, `TStatusBar.Panels[].Text`, and form titles;
- To write a literal `&`, write two: `'A && B'` → `A & B`.

Demo: `demos/accel` (one of each control type, clicking echoes to a log label); acceptance test: `tests/cdp_accel_audit.py` (114 assertions across Alpine + Ext).

## 5. Configuration

Command-line parameters (for the complete table, refer to `--help` in `src/core/lwapp.pas`):

```
--config=path  --port=  --root=  --form=  --client=alpine|ext  --ext=
--extdir=  --theme=  --title=  --timeout=  --trust-proxy  --ajax-cors
--ssl  --ssl-host=  --ssl-cert=  --ssl-key=
       (--tls-cert= / --tls-key= are aliases of the last two; supplying a cert or a key automatically enables HTTPS)
--verbose  --nogui  --patch=1  --log=path  --help
```

INI configuration (template `lazarusWeb.ini.sample`, placed next to the exe and renamed `<exe name>.ini` or `lazarusWeb.ini`): `Port` / `Theme` / `ExtDir` / `Patch` / `Client` / `SSL` / `SSLHost` / `SSLCert` / `SSLKey`.
Priority: **built-in default < config file < command line**. Encoding must be UTF-8 or pure ASCII.

`--ssl-host` / INI `SSLHost` is the certificate host name — enter the domain or IP as it appears in the browser address bar, and it must match the certificate's SAN; it is not the listening address. For a command-line example with a formal CA / private CA non-self-signed certificate, see `deploy/README.md` §1.1.

Choose one of two rendering layers (**Alpine.js by default**: when `--client` is not specified it auto-detects — if both sets are available it prefers alpine, and if only one is available it uses that one; the alpine files are built in and always available, so the effective default is alpine):

- `alpine` (default): Alpine.js 3.14.9 (built-in `src/client/alpine.min.js`), **no ext directory needed**, the lightest deployment;
- `ext`: Ext JS, requires an `ext-x.x.x/` directory (about 75MB); enabled explicitly with `--client=ext`, INI `Client=ext`, or URL `?client=ext`. The protocol is completely identical for both.

### 5.1 Color Schemes of the Alpine Rendering Layer (7 Sets + Follow System)

Only the Alpine rendering layer has this set (the Ext layer still uses `--theme=` to choose an Ext theme).

**7 color schemes, in two color families**:

| Scheme | Name | Best for |
| --- | --- | --- |
| `light` | Light | Default, blue-grey business style |
| `paper` | Paper beige | Long stretches reading tables/documents, warm and easy on the eyes |
| `mint` | Eye-care green | A green-tinted white background for eye comfort |
| `contrast` | High contrast | Pure black text on white + black borders, strong light / projection / color-vision deficiency |
| `dark` | Dark | General dark theme |
| `midnight` | Midnight blue | A cooler, bluer enterprise back-office night theme |
| `forest` | Forest green | A green-leaning dark theme, comfortable for long stretches staring at logs |

Plus `auto` (follow the system, resolved to light or dark).

- The ☀/☾/◐ buttons on the right of the form's title bar open these 8 options; **the icon shape indicates the color family** (sun = light family, crescent = dark family, half circle = follow system), and **the fill color is the current theme's accent color**; the choice is stored in `localStorage['lw-theme']` and stays consistent across refreshes and tabs;
- "Follow system" listens to `prefers-color-scheme`, so the page changes immediately when the system switches to dark;
- At design time you can set the form property `LWTheme` in the object inspector (`twAuto`/`twLight`/`twDark`/`twPaper`/`twMint`/`twMidnight`/`twForest`/`twContrast`, default `twAuto`) as the **first-time default**; once the user has chosen manually, the user's local choice takes precedence;
- To force a switch in code: `LW.theme.set('midnight')` / `$lwTheme.set('paper')` (`LW.theme.get()` reads the preference including auto, `LW.theme.current()` reads the value actually in effect, `LW.theme.dark()` tells whether the current scheme is in the dark family, `LW.theme.modes()` lists all available options); to hide the title-bar buttons: `LW.theme.button(false)`;
- Switching themes dispatches the `lw:themechange` event, with `detail = { theme, pref, dark }`. **Use `detail.dark` to judge light vs. dark**, not `theme === 'dark'` — there are three dark schemes; business code that draws its own canvas should listen for it and redraw;
- All colors are at the top of `src/client/lw-alpine.css` (`:root` light + dark baseline blocks + per-variant override blocks, 61 `--lw-*` variables in total); there are no color literals in the component rules. For how to add a theme and the constraints, see the file-header comment and pitfall 174 in `NOTES.md`.

> Using an old project and cannot see the new color schemes? The front-end resources are a **copied set in the project directory's `lw/`**. Just copy the three files from the new `src/client` over:
>
> ```
> copy /Y src\client\lw-alpine.css <your project>\lw\
> copy /Y src\client\lw-alpine.js  <your project>\lw\
> copy /Y src\client\alpine.min.js <your project>\lw\
> ```
>
> New projects are copied automatically by the wizard, so you need not worry about it.

## 6. Deployment

Minimal directory (self-contained, **Alpine.js rendering layer by default, no ext directory needed**):

```
yourapp.exe
src\client\alpine.min.js    Alpine.js itself (44KB, loaded with defer, no CDN)
src\client\lw-alpine.js     Renderer/coordinator (shared by both template layers; adaptation only in this layer)
src\client\lw-alpine.css    Styles, including CSS variables for the 7 color schemes (§5.1)
tpl\                        (Optional: window/flat form templates <form name>.html; read by both Alpine and Ext layers)
favicon.ico                 (Optional: browser tab icon)
cert\                       (Optional: when SSL is enabled with your own PEM, put server.crt/server.key/ca.crt here)
libssl-3-x64.dll + libcrypto-3-x64.dll  (Optional: required in the exe's directory when SSL is enabled)
```

All three alpine files are **indispensable**: missing `alpine.min.js` (or `lw-alpine.js`) makes auto-detection treat alpine as unavailable and fall back to ext; missing `lw-alpine.css` leaves the page runnable but with no styling at all. The files may be laid out flat (either alongside the exe or in an `lw\` subdirectory — both are compatible; see the flat/semi-flat layout table in the README "Deployment" section for the lookup order).

The Ext JS rendering layer is **optional** (not deployed by default): when needed, put `ext-x.x.x\` next to the exe (the full set is about 75MB; a reduced version is about 23MB, see `tools\make_ext_min.bat`) and switch explicitly with `--client=ext`; the front-end files become `lw.js` + `lw.css`.

### Site Icon (favicon)

The small icon on the browser tab is not drawn by the framework — **just place a `favicon.ico` file**:

- Lookup order: the directory specified by `--root` → the exe's directory → if neither has one, `/favicon.ico` returns 204 (the browser shows its default icon, no error);
- On a hit it returns 200 + `image/x-icon` + `Cache-Control: public, max-age=86400` (file-level caching is fine; after changing the icon, users see it within at most a day; **Ctrl+F5 refreshes it immediately**);
- The HTML head of both the Ext and Alpine shells already carries `<link rel="icon" href="/favicon.ico" type="image/x-icon">`, so no front-end change is needed;
- It is recommended to make a multi-size ico (16/32/48px); SVG does not work in some browsers without conversion;
- Troubleshooting: if the site was visited during an earlier deployment (when it returned 204), the browser may have cached the empty response — just force-refresh or close and reopen the tab;
- A reverse proxy needs no forwarding rule for favicon (the app answers it directly, without going through a worker).

**Note**: when upgrading from an old version, users' browsers are very likely to have cached the old 204 empty response; mention Ctrl+F5 once in the release notes.

- Two ways to do HTTPS: ① **built into FPC**: add `--ssl` to the business exe or lwhyper; if no certificate is given, a self-signed certificate is generated automatically, and you ship `libssl-3-x64.dll` + `libcrypto-3-x64.dll` with the package (a cluster enables it only on the outer lwhyper layer, while workers remain plaintext, see pitfall 160); when using a formal CA or private CA certificate, add `--ssl-cert=/--ssl-key=` and set `--ssl-host=` to the domain/IP in the certificate SAN; for a complete example see `deploy/README.md` §1.1; ② terminate TLS at a nginx/Caddy reverse proxy, examples in `deploy/nginx.conf` and `deploy/Caddyfile` (including `/lw/ws` Upgrade, `/lw/api/poll` unbuffered, a 100MB upload limit, and `/ext/` caching);
- TLS security baseline: the bundled OpenSSL 3.x is measured to support **TLS 1.2 / TLS 1.3**; the application itself provides no configuration for a minimum version, cipher suites, mTLS, HSTS, or certificate hot-reload; when you need these capabilities, configure them explicitly at the nginx/Caddy outer layer and terminate TLS there. The project does not explicitly enable HTTP/2, and `TFPHttpServer.UseSSL` does not guarantee that the browser uses h2;
- Behind a reverse proxy, add `--trust-proxy` (so the IP in the logs is the real client);
- Health probe `GET /lw/healthz`;
- Multiple workers on one machine: use the built-in load balancer `tools\lwhyper.exe` (benchmarked against uniGUI Hyper Server: worker guarding + reverse proxy + sid stickiness + WS pass-through + crash restart); for full usage see `docs/WHYPER_en.md`; it is strongly recommended to add `--patch=1` to the worker parameters;
- An nginx cluster requires sticky sessions (`ip_hash`) — sessions live in process memory, and external Redis is not implemented;
- On Linux: build with `build.sh`, add `cthreads` to the project's uses clause, install libsqlite3; see `deploy/README.md` for a systemd example.

## 7. Capacity and Performance

- A single event (full output) takes about 6.3ms → 4.3~6.3ms after incremental patches are enabled;
- Single-process throughput: about 57.9 events/sec for full output, 150~163 events/sec with `--patch=1`;
- Comfort zone 10~20 active users, 40 as the upper limit; 200+ idle sessions can be held (about 1MB/session);
- Scale-out: lwhyper with N workers ≈ N×150 events/sec (workers recommended at cores/2);
- For measurement methods and data see `docs/BENCH_en.md`, and for the optimization roadmap see `docs/SCALE_en.md`.

## 8. Common Problems (Troubleshooting Quick Reference)

| Symptom | Cause / Solution |
| --- | --- |
| Changed the form but no effect | Rebuild did not include `-B`; or the exe is still running and the link failed (close the exe first) |
| lfm streaming fails with Unknown property | LW controls lack published properties such as TabOrder; delete them from the lfm; do not put TBufDataset FieldDefs into the lfm |
| TDBNavigator crashes on creation | Write the real class name `TLWDBNavigator` in the lfm and `RegisterClass(TLWDBNavigator)` (pitfalls 29/41) |
| DBGrid shows (MEMO) | Change the SQLite string column to `VARCHAR(n)` (pitfall 9) |
| Save "succeeds" but data is lost after restart | `sqoAutoApplyUpdates` does not commit the transaction; call `SQLTransaction.Commit` explicitly after Post/Delete |
| A control shows a grey box | That control is a placeholder; check `docs/CONTROL_MATRIX_en.md`; the server-side logic still runs normally |
| The program exits instantly (no output) | The terminal tool launched it inside a Job Object and it was reclaimed; see the panel log in the GUI version; pitfall 108 |
| The worker restarts endlessly | A DelimitedText replacement-semantics pitfall on the command line, already fixed (pitfall 106) |
| FPImageException | Usually a stand-in; the real culprit is often an sqlite lock (pitfall 107) |
| SQLite database is locked | WAL + busy_timeout=10000 + CommitRetaining before writes (pitfall 9) |
| Public-facing log IPs are all reverse-proxy addresses | Add `--trust-proxy` |
| An orphan socket remains after a port is force-killed | `LISTENING PID 0`; switching ports is the easiest fix |
| The browser tab has no icon (still the default globe) | No favicon.ico alongside the exe or under `--root` → add one; or the browser cached the old 204 empty response → Ctrl+F5 force-refresh (pitfall 144) |
| **Local 127.0.0.1 works, but all phones/tablets fail at once** (suddenly all fail after switching Wi-Fi or rebooting) | Check the machine's inbound firewall first, no need to dig through code: run `Get-NetConnectionProfile` to see whether the current profile is Private or Public, then `Get-NetFirewallRule -DisplayName 'mobile_demo' \| select Profile` to see which Profile the allow rule landed on — **when the two do not match, all inbound traffic is dropped**, loopback is unaffected, hence "local works, devices all fail". Run `tools\allow-firewall.bat` as administrator (writes `profile=any` TCP/UDP + a port fallback), no service restart needed (pitfall 159) |
| A phone/tablet cannot open the page ("network connection lost" / unreachable), but some device can | ① **The URL must include the port** (`http://192.168.x.x:8090/`); writing only the IP goes to port 80, which the server does not listen on; the banner's `LAN:` line gives the full address to use. ② iOS: Settings → Privacy & Security → **Local Network** → allow Safari (once denied it fails silently forever). ③ Make sure the devices are on the same Wi-Fi / same subnet, not a guest network or a separate 5G SSID. ④ Turn off VPN / proxy / iCloud Private Relay. ⑤ Verify separately with `/lw/healthz`: if it returns ok, the network is fine and the problem is at the page layer |
| Controls do not rearrange after opening on a phone | Under the new mechanism the template does not rearrange controls; controls always use the LFM absolute coordinates; anything beyond the viewport is viewed by panning/scrolling |
| Changed the template but no effect | The template should be `<root>\tpl\<form name>.html` with `lw-tpl-mode:window|flat` in the header; the client script is cached → use `Ctrl+F5` to force-refresh; if an old `.flat.html` also exists, compatibility rules keep it in flat mode |
| Selected window mode but the whole page still displays | An old `<form name>.flat.html` remains in `tpl\`; delete it and force-refresh; or the `.html` header says `lw-tpl-mode:flat` |
| A service started from an AI terminal/script disappears after a while with no logs | The command runs in a kill-on-job-close Job Object and gets reclaimed; a background task may also be collected when the turn ends → start it with `Start-Process` (detached from the Job) or from a real user terminal (pitfalls 108/145) |

For more cases and debugging methodology: `docs/DEBUGGING_en.md`; search the 212 pitfalls by number in `docs/NOTES.md` (older conclusions in pitfalls 23/66/108 and others have been revised by later pitfalls — follow the annotations).

## 9. Known Limitations

- Modal timeout 180 seconds; only one dialog at a time per session;
- `TOpenDialog` cannot browse the server's disk (it can only upload files);
- `TSplitter` can be dragged to adjust its position (pitfall 186); `Anchors` do not do front-end snapping calculations;
- High DPI is treated as 96 (lfms designed at 125%/150% are scaled back automatically);
- Direct PDF output is temporarily replaced by the browser's "Save as PDF"; external session storage in Redis is not implemented;
- Unsupported controls show a grey-box placeholder on the browser side (the server side is still alive), without affecting other controls;
- `TLWCamera` desktop viewfinding is a simplified version (single-frame capture, no burst/manual focus/resolution switching);
- On desktop LAN http pages the camera **cannot** be called (a browser hard limit), so only an image file can be chosen; for a full desktop camera experience, serve the page over HTTPS or access it via local localhost.

---

# Part II  Development Part

## 10. Source Structure

```
src/
├── lwcore.lpk / lwserver.lpk      Runtime packages (IDE-generated, aggregate units)
├── design/lwdesign.lpk            Design-time package (IDE wizard/component palette)
├── client/                        Front-end runtime: lw.js lw.css lw-alpine.js lw-alpine.css alpine.min.js
├── lib/                           Package build outputs (git-ignored)
└── core/                          All core units (about 30)
```

Key units in `core/` (responsibilities are in the file-header comments):

| Unit | Responsibility |
| --- | --- |
| lwbase.pas | Base types/JSON utilities; `LW_VERSION`; event whitelist `IsLWClickEvent` |
| lwws.pas | nogui widgetset patch: virtual display 1920×1080@96DPI + GDI completion |
| lwform.pas | `TLWForm` base class (overrides ShowModal/DoClose to implement synchronous modal) |
| lwwriter.pas | LCL tree → JSON (KindOf mapping, whitelist properties, internal control filtering) |
| lwsession.pas | Session = one tab + one LCL tree; push queue; incremental patch snapshot |
| lwdispatch.pas | Browser events → RTTI calls to real control events; vals written back via LWApplyValue |
| lwhttp.pas | fphttpserver routing (/lw/api/*, /ext/, /lw/download, /lw/view…) |
| lwapp.pas | Facade: Register/SetLogin/Run; command-line and INI parsing |
| lwdlg.pas | Dialog rerouting (LWInstallDialogs) |
| lwdiff.pas | Incremental patch diff (two payloads → ops) |
| lwws/lwwebsocket.pas | WS carries only event requests/responses; push goes through the long-poll cursor |
| lwdbgrid.pas / lwdbnav.pas | TLWDBGrid / TLWDBNavigator (write the real class names in the lfm) |
| lwchart/lwui/lwweb/lwreport/lwlogin/lwcaptcha/lwcamera/lwpanel/lwrlog | Chart / gauge-color-picker-mask / rich content / report / login / graphical CAPTCHA / camera / panel / log |
| lwhyper.pas | Load-balancing core (shared by the tools' console/GUI versions) |
| lwnewproject.pas | Project skeleton template (shared by the IDE wizard and tools\lwnew) |
| lwproxyws.pas | Auto-generated (gen_proxyws.py), GUI-build-only proxy widgetset; do not edit by hand |

## 11. How It Works (One-Minute Version)

1. `TLWApp.Register(TMainForm)` only records the form class; `Run` starts the HTTP service;
2. Browser `GET /` → `POST /lw/api/session` → the server creates a real `TMainForm` instance and runs `OnCreate`, and `lwwriter` serializes the whole LCL tree into JSON and sends it down;
3. Click → `POST /lw/api/event {sid,id,ev,val,vals}` → `lwdispatch` uses RTTI to find the control, first writes the values back with `LWApplyValue` and then triggers the real event (buttons go through native Click to preserve ModalResult semantics) → re-serializes and returns the new tree;
4. `ShowModal` uses `TEvent.WaitFor` in 200ms slices to genuinely block the event thread, and the browser's long polling pushes the modal instruction to the tab; clicking OK brings the modal result back via `/lw/api/dlg`;
5. Push always goes through the long-poll cursor (`poll?after=N`, a queue of 64); WS carries only events;
6. The browser's `lw.js` reconciles incremental updates by id; with `--patch=1` the server first diffs (lwdiff) and sends only ops, and if the client's `tver` does not match it automatically falls back to a full payload for self-healing.

For a deeper read: `docs/HOW_IT_WORKS_en.md` (with key source line numbers); design constraints such as why a full RTTI dump is impossible and KindOf order sensitivity are there too.

## 12. Thread Model (Read Before Making Changes)

- fphttpserver uses one thread per request; the event thread handles `/lw/api/event`;
- The long-poll thread blocks for 20s; the Sweep thread cleans up sessions (20-minute timeout by default);
- The GUI version additionally has an accept background thread + a panel TTimer;
- **Concurrent form creation corrupts the LCL global glyph cache**: form creation/destruction/serialization must go through the `LWLCLEnter/Leave` gate (pitfall 100); event handling deliberately does not;
- Session-level reentrant execution lock `FExec` (pitfall 71): during a modal, other requests in the same session queue up;
- All session data lives in process memory → clusters must be sticky, and restarting a worker loses its sessions.

## 13. Debugging

- `--verbose` prints every request and exception stack; `--log=path` writes to disk;
- GUI version panel: File/Admin menus + a live log (limited to 4000 lines) + a three-cell status bar;
- lwhyper has its own `/lw/hyper/status` worker-detail endpoint;
- Stress tests: `tools/bench_concurrency.py` (stepped load), `tools/pipe_bench.py` (pipe benchmark); profiling switch `LW_PROF`;
- The location process of four real bugs + nine debugging methodologies: `docs/DEBUGGING_en.md`.

## 14. Testing

Unified entry point (automatically starts/stops the service):

```
python tests/run_with_server.py <exe path> <test script> [port] [extra exe args]
```

- **HTTP-level regression** `tests/t_*.py` (about 25: controls/db/dbaware/dialog/files/login/multitab/ws/hyper_ws/writeback_audit…), hundreds of assertions;
- **CDP browser probes** `tests/cdp_*.py` (connect to headless Edge via the Chrome DevTools protocol on port 9237, requires websocket-python): first-screen rendering / screenshots / console errors;
- **Offline unit tests**: `tests/lwdiff_case.lpr` + `t_lwdiff_fuzz.py` (diff fuzz, pure fpjson, no lazbuild needed);
- **Support audit** (re-run after changing lwwriter/lw.js):

  ```
  tools\build_audit.bat     → docs\CONTROL_MATRIX_en.md
  tools\build_dbcheck.bat   → docs\DB_AWARE_MATRIX_en.md
  ```

## 15. Extension Development

Adding rendering support for a new control (standard path):

1. Add a kind in `lwwriter.KindOf` (mind the branch order; KindOf order is sensitive);
2. Add events to the `lwbase` event whitelist as needed;
3. Add a rendering branch and a write-back branch in `lw.js` (and in lw-alpine.js if both ends must match);
4. Place an instance in `demos/audit` or `demos/controls`;
5. Re-run `lwaudit` to update the matrix, plus `tests/t_controls.py` for regression;
6. Write the mapping into `docs/MAPPING_en.md`.

The front-end protocol fields (payload/ops/tver/seq cursor) are in `docs/SCALE_en.md` §2 and `docs/HOW_IT_WORKS_en.md`; changes related to lwproxyws must go through `gen_proxyws.py` for regeneration.

## 16. Form Template Development Guide (Window + Flat)

Templates **no longer rearrange controls**: controls are always absolutely positioned by the LFM's `Left/Top`, and events, incremental patches, and the internal structure of containers all stay as-is. A template is only a layer of background/decoration HTML, and the business form needs no code changes at all. Window mode and flat mode **share one template file**, `<root>\tpl\<form name>.html`, and the mode marker in the file header determines how it is rendered:

Templates are split into two files by platform, with **desktop window and flat modes sharing the same `.html`**:

| Platform | Template file | Header marker | Page appearance | With no template |
| --- | --- | --- | --- | --- |
| Desktop · window | `<root>\tpl\<form name>.html` | `lw-tpl-mode:window` | The existing floating window, movable/resizable, with the template as the client-area background | What you see at design time is what you get |
| Desktop · flat | The same `.html` | `lw-tpl-mode:flat` | A full web page: no title bar/border/dragging/resizing, the page itself scrolls | Same as above |
| Mobile | `<root>\tpl\<form name>.m.html` | Either of the above two | Mobile reads only this template (also a decoration layer, controls not rearranged; the form keeps its design width/height, and anything beyond the viewport is viewed by horizontal panning) | Direct LCL layout (the desktop `.html` is not read) |

If both markers appear in the same file, **flat takes priority**. The generator writes two copies — desktop `.html` and mobile `.m.html` — in each of the window and flat modes (the mode is distinguished by the header marker); the old `.flat.html` is still detected for compatibility (its presence means flat mode) — delete it when you want to switch back to window mode.

### 16.0 One-Click Generation: IDE Tools Menu (lwdesign)

After installing the design-time package `lwdesign`, the IDE's **Tools menu** gains an item: "**Generate lazarusWeb Form Template (Current Unit LFM)**":

1. Open the form unit (.pas, which automatically finds the same-named .lfm) or open the .lfm directly;
2. Click that menu → a "Window mode / Flat mode / Cancel" choice pops up;
3. After choosing, **two files** are generated under `<project directory>\tpl\`: the desktop `<form name>.html` and the mobile `<form name>.m.html`; both get the header marker for the chosen mode (window writes `lw-tpl-mode:window`, flat writes `lw-tpl-mode:flat`). **Desktop window and flat modes share the same `.html`; no second desktop file is generated**; if a file already exists, it asks separately whether to overwrite each one (overwriting replaces the old mode marker too);
4. Generated content: a file-header comment listing the parsed top-level controls (class names + design-time `Left/Top/width/height`), a self-check report, and a `<style>` + empty `<div>` decoration layer. There are **no** `{%control name%}` placeholders, and no flow/percentage-width/main-area-stretching CSS; control positions are drawn entirely by the framework from the LFM;
5. Copy the two files to the **runtime root directory's** `tpl\` (or, if the project directory is the runtime root, they take effect as soon as they are generated), and force-refresh the browser (`Ctrl+F5`, since the client script is cached) to see the effect; mobile reads only `.m.html`, and deleting it falls back to LCL layout (the desktop `.html` is not read);
6. After changing the design-time package you must **Package → Open Package File → lwdesign.lpk → Compile → Install → restart the IDE**, otherwise the menu still runs the old one-click generation logic.

Parsing scope: the form's **top-level visual controls** (arranged in visual order by Top/Left); non-visual controls such as data sources, dialogs, menus, and image lists, plus the status bar, are skipped automatically. Parsing proceeds through a three-state machine of "object hierarchy + collection item blocks + parenthesized string blocks", so `end`/`end>` in collections such as `TListView.Columns` and `end` inside multi-line strings no longer damage the object hierarchy (pitfall 163, with `demos/gallery/ugallery.lfm` as the regression sample). An empty form can also generate an empty decoration layer, and the prompt will state that there are no top-level visual controls.

Regression: `tests/tplgen_test.lpr` performs string assertions on six forms of mobile_demo, gallery, and dbaware and on `tests/fixtures/tpl_two_cols.lfm` (including new assertions: a single desktop file + a mobile `.m.html` pair, mode markers, no placeholders, and preserved design coordinates), and keeps the historical regression of the old flow generator; `tests/run_fixed_regression.py` is the fixed entry point.

### 16.1 Files and Routing

- Template path: look in `<root>\tpl\` first, then in `<exe directory>\tpl\`; desktop reads `<form name>.html` (window/flat share this one file), mobile prefers `<form name>.m.html`. When `--root` is not specified, `LWResolveRoot` probes upward from the current directory/exe directory, so it cannot simply be equated with "always the exe directory";
- Delivery: desktop requests `GET /lw/tpl/<form name>.html`, mobile requests only `GET /lw/tpl/<form name>.m.html` (with no template it no longer reads the desktop `.html` and falls back to LCL layout), and the response carries `Cache-Control: no-store` — **changing the template content and refreshing the page takes effect with no recompilation**; for compatibility with old versions it still probes for a same-named `.flat.html` and treats a hit as flat mode;
- Security: filenames block path traversal (out-of-bounds returns 403); a missing template returns 404 and the client silently falls back to the design-time layout without a page error;
- Both layers support it: Alpine (`lw-alpine.js`) and Ext (`lw.js`, `--client=ext`) use the same template mechanism — the same `lw-tpl-mode` markers and the same compatibility with the old `.flat.html`. In both layers the template is only a background decoration layer; controls always keep their design-time absolute coordinates and are not rearranged. When the Ext layer detects `flat`, it removes the title bar/border/dragging/resizing and sets width/height to max(design size, viewport) (on a narrow screen it keeps the design width and is panned for viewing). Loading and fallback of the mobile `.m.html` is handled by the Alpine layer (the Ext layer has no mobile layout mechanism and always reads only `.html`).

### 16.2 Template Syntax

A template = a file-header mode marker + a `<style>` block + an empty `<div>` decoration layer. The client mounts the whole template as a background layer into the form's client area (inserted first, with `pointer-events:none`); the control DOM is still drawn in the client area at absolute coordinates, with no DOM relocation:

```html
<!DOCTYPE html>                       <!-- Needed only in flat mode -->
<!-- lw-tpl-mode:flat -->             <!-- or window -->
<!--
  Flat-mode template for MainForm (starting skeleton)
  Top-level controls (design-time coordinates for reference):
    Button1 : TButton  (left=163, top=225, 113x38)
    ...
-->
<head>
<style>
  .tpl-mainform-flat { position: absolute; left: 0; top: 0; right: 0;
    bottom: 0; box-sizing: border-box; pointer-events: none; }
  /* Add a background color/gradient/pattern/description text and other decoration here */
</style>
</head>
<body>
<div class="tpl-mainform-flat"></div>
</body>
</html>
```

Window mode is an HTML fragment (no doctype/head/body), with the same structure: a mode marker + `<style>` + `<div>`. The business side's workload is exactly this one piece of HTML; `.pas`/`.lfm` need no changes at all. **Old `{%control name%}` placeholder templates no longer drive flow layout**: their placeholders are replaced with empty `<span>`s and controls are still displayed at design-time coordinates; if you need flow layout, switch back to the old client or rewrite the business layout by hand.

### 16.3 Common CSS Hooks

| Hook | Description |
| --- | --- |
| `.lw-tpl` / `.lw-tpl-backdrop` | Template background layer (added automatically by the framework, filling the client area, `pointer-events:none`) |
| `.lw-win.lw-flat-form` | Flat-mode form root: no border/title bar/drag corner, width/height not less than the design values (pannable on narrow screens) |
| `.lw-theme-fab` | Color-scheme floating button (circular, automatically attached in flat mode and in window mode under mobile layout; draggable with a remembered position; the framework attaches/removes it automatically by layout, and hides the title-bar icon at the same time) |
| `html[data-lw-layout="mobile"]` | Mobile-layout root marker (maintained automatically by the framework) |
| `html[data-lw-input="touch"]` | Touch marker (independent of width) |

A template's own classes (such as `.tpl-mainform-flat` in the example) affect only the decoration layer; controls are still positioned by the framework's `.lw-n` according to LFM coordinates, and template CSS should not change their `left/top`.

### 16.4 Breakpoints, Hard Override, and Fallback (Template-less Forms)

- Breakpoints: a viewport ≤834px enters the mobile layout, ≥1100px exits it, and 835~1099 keeps the current state; if the first landing is in the hysteresis zone, touch capability decides;
- Hard override: URL `?layout=mobile|desktop|auto` > `sessionStorage['lw-layout']` > automatic detection; at runtime `LW.layout.set()/get()`;
- **Forms with no template (both ends consistent: what you see at design time is what you get)**: on desktop they are absolutely positioned as-is (exactly the historical behavior); on mobile they keep their design size (font size unchanged), are fixed to the left with title-bar dragging disabled, and anything beyond the viewport is scrolled/panned via `#lw-root` (`html[data-lw-pan]`); **there is no overall proportional scaling** (scaling down to a 390px screen leaves fonts at 0.3× and unreadable — rejected after measurement);
- Forms with a template also follow the same geometry rules: window mode does not change the form's position/size, and flat mode sets width/height to max(design values, viewport) (on a narrow screen it keeps the design width and can be panned for viewing, never squeezed); neither mode moves the controls;
- **The flat mode's background color follows the theme**: for the template decoration layer's background/text colors, write `var(--lw-win-bg)` / `var(--lw-fg)` (the generator does this by default). Hard-coding a fixed color makes every theme show the same background block.
- **The theme entry changes form by layout/mode**: desktop window mode uses the color-scheme buttons in the title bar (☀/☾/◐); **flat mode** (the whole title bar is hidden) and **window mode under mobile layout** (the title bar is only 28px tall, and a 22px icon is too imprecise for a finger) instead use the semi-transparent circular floating button `.lw-theme-fab` at the bottom right. The floating button is **draggable** (its position is remembered in localStorage and survives refreshes; flat mode and window mode remember separately), and a click expands the same color-scheme menu (automatically choosing the expansion direction based on the available space above/below); under mobile layout the title-bar icon is hidden by CSS, and under desktop layout the floating button is automatically removed — the two never appear together. The server-side `LWThemeButton = False` and modal forms do not attach it. A phone has no Alt key, so a keyboard shortcut alone is not enough.

### 16.5 Testing

See Section 14 for the unified run method; the fixed regression entry (file/tracking, template generator, TLS parameter validation and HTTPS healthz, browser-independent):

```
python tests/run_fixed_regression.py
```

Template-related CDP probes (require headless Edge, debug port 9239; they can also be run together via `python tests/run_fixed_regression.py --with-cdp`). Note: `cdp_desktop_tpl.py`, `cdp_tplgen_gallery.py`, and `cdp_tplgen_dbaware.py` target the old "placeholder + DOM relocation" flow templates; the new version has changed to a decoration layer that does not rearrange controls, so these three are kept only as historical regression references and are no longer the acceptance basis for the new template mechanism:

```
python tests/cdp_desktop_tpl.py    # Desktop templates: apply / geometry invariant / three-state switching / no-template fallback, 7 items
python tests/cdp_tplgen_gallery.py # Generator output (gallery): measure the main-area height at three viewports, 7 items
python tests/cdp_tplgen_dbaware.py # Generator output (dbaware): login page + floating-window main form, 6 items
python tests/cdp_dbaware_dark.py   # HTML readability inside dark-theme frames (pitfall 165):
                                   #   prerequisite: dbaware.exe --port=8155 LW_CAPTCHA_DEBUG=1
python tests/cdp_colorpicker.py    # Color block pops the palette anchor + color-selection write-back chain (pitfall 166):
                                   #   prerequisite: same as above (shares port 8155 with the dark-theme probe)
python tests/cdp_dbaware_regress.py # Login page vertical line + skip login on browser close (pitfall 167):
                                   #   prerequisite: dbaware.exe --port=8156 LW_CAPTCHA_DEBUG=1
python tests/cdp_mobile_demo.py    # Template form: desktop / 390 / switch back / hard override / routes, 19 items
python tests/cdp_fit_scale.py      # No-template fallback pan mode, 23 items
python tests/cdp_device_probe.py   # Detection signals, 8 scenarios
python tests/cdp_updown.py         # TUpDown forms and linkage on both ends, 7 items
```

The generator's parsing/content also has console tests (no IDE dependency, compiled and run directly with fpc):

```
fpc -FE. -FU. -Fu../src/design tests/tplgen_test.lpr
tests/tplgen_test.exe demos/gallery/ugallery.lfm tests/out_tpl
```

Note: for simulated viewport changes in CDP, use `Emulation.setDeviceMetricsOverride` to **directly overlay the new size** — do not clear first; clearing instantly returns to the real window width (1200, hitting the exit breakpoint), and the hysteresis zone locks in the misclassification (`MOBILE_en.md` §8.8).

## 17. Repository Notes

- The root-level `src - 副本 (N)`, `src稳定版20261111`, `src高吞吐量`, etc. are historical snapshots — **the only authoritative source is `src/`**; likewise `demos/gallery - 副本`;
- Flat deployment copies such as `demos/gallery/lw/` cause "changes to src/client have no effect" (pitfall 93);
- `CrossSocket/` currently has no project referencing it; `patches/` are FPC MIPS64 patches (for the Loongson scenario);
- `packagefiles.xml` is the IDE user-package link list (including local third-party package paths), not a build script;
- `src/core/backup/`, `*.ppu/*.o`, and `tmp/` are local artifacts, already covered by `.gitignore`.
