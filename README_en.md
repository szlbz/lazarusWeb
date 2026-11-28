# lazarusWeb

Quickly convert Lazarus desktop programs into web applications that run in the browser, using the **real LCL control tree** directly serialized into the UI; **the default rendering layer is Alpine.js** (built-in dependency, zero extra deployment), Ext JS is an optional rendering layer (you need to provide the ext directory yourself and explicitly enable it with `--client=ext`). Business programs only need to change the form base class from `TForm` to `TLWForm`; all other code (events, properties, `.lfm`) stays as-is, and the program can run in the browser as a service program.

Browser (Alpine.js default / Ext JS optional) Server (Lazarus, nogui widgetset)
| Browser side (Alpine.js default, Ext JS optional) | Communication | Server side (Lazarus, nogui widgetset) |
| :--- | :---: | :--- |
| `lw-alpine.js` + `alpine.min.js` renderer/coordinator<br>(optional: `lw.js` + `ext-<version>/`)<br><br>Native DOM/CSS (optional: Ext.window/panel/grid/...)<br><br>`WS sends events / long-poll cursor receives pushes` | <br>**HTTP←→JSON**<br><br> | `lwhttp` fcl-web multithreaded server<br>`lwsession` one LCL control tree per tab<br>`lwwriter` LCL tree→JSON<br>`lwdispatch` events→RTTI calls business code<br>`lwws` nogui patch (virtual display/canvas) |

## Requirements

- FPC 3.3.1/3.2.2 + Lazarus
- Alpine.js (built-in dependency)
- Ext JS 7.0.0 (GPLv3 version, **optional**: not included in the release package; you need to obtain it from Sencha's official channels and place it in `ext-7.0.0\`; if not placed, the built-in Alpine.js rendering layer is used by default)
- **Ext support is an optional feature; ext-js files must be obtained by the user, and licensing compliance is the user's responsibility.**

## Control Installation (Lazarus IDE design-time packages)

To open forms containing lazarusWeb controls in the IDE designer, and to use the "New Project Wizard" and the "Generate lazarusWeb Form Template" Tools menu, you must process the four packages in a **fixed order**. The order cannot be reversed: `lwserver` / `lwvst` both depend on `lwcore`, and `lwdesign` (the design-time package) depends on the first three. Skipping steps will cause `Can't find unit lwcore / lwserver / lwvst` errors during Install.

| Order | Package | Type | Dependencies | What to do in the IDE |
|---|---|---|---|---|
| 1 | `src\lwcore.lpk` | RunAndDesignTime | LCL / FCL / fcl-image | **Compile only** (Compile), do not Install |
| 2 | `src\lwserver.lpk` | RunAndDesignTime | LCL / FCL / **lwcore** | **Compile only** (Compile), do not Install |
| 3 | `src\lwvst.lpk` | RunAndDesignTime | LCL / **lwcore** / lclextensions_package / laz.virtualtreeview_package | **Compile only** (Compile), do not Install |
| 4 | `src\design\lwdesign.lpk` | DesignTime | LCL / IDEIntf / **lwcore** / **lwserver** / **lwvst** | **Compile → Install** (will rebuild `lazarus.exe`, then restart the IDE) |

The purpose of the three-layer dependency—**the two build chains do not pollute each other**:

- Headless chain: `lwcore` + `lwserver`. Neither references VirtualTreeView, so `--ws=nogui` can compile, used for Linux/no-X deployment targets.
- GUI chain: `lwvst` (`TLWDBVirtualTreeView`, requires real GDI) + `lwdesign`. These two packages **can only be compiled with the target IDE's widgetset (native win32)**, do not add `--ws=nogui`: `lclextensions_package` / `laz.virtualtreeview_package` only have `include/<widgetset>` and `include/intf/<widgetset>`, no nogui version, and will report `Cannot open include file "uses.inc"`.
- For headless projects requiring multi-column/virtual node trees, use `TLWDBTreeView` in `lwcore` instead (see example `demos\treedemo_nogui`, verified to run under nogui build).

Specific steps:

1. Register the four packages from the command line first (so the IDE recognizes them; otherwise new projects report "package not found"):

   ```
   tools\install_design.bat
   ```
   Equivalent manual commands (replace `C:/111/lazarus` with your Lazarus directory):
   ```
   lazbuild --add-package-link src\lwcore.lpk
   lazbuild --add-package-link src\lwserver.lpk
   lazbuild --add-package-link src\lwvst.lpk
   lazbuild --add-package-link src\design\lwdesign.lpk
   ```
   Note that `--add-package-link` is followed by **a space + path**; writing it as
   `--add-package-link=...` will be rejected by the current lazbuild (`does not allow an
   argument`) and nothing will be registered.
   `--add-package-link` only "registers/recently opened", **it is not equal to installation**.

2. Open Lazarus, and in the order of the table above, open each package via `Package → Open Package File → <package>.lpk`.
   For the first three, click **Compile** (only compile ppu, do not Install); for the fourth `lwdesign.lpk`,
   click **Compile → Use → Install**, choose "Yes" when asked whether to rebuild the IDE, wait for the rebuild to finish,
   and **restart Lazarus**.

3. After restart, verify: `File → New → Project` shows two lazarusWeb templates,
   the component palette shows the **lazarusWeb** page, and the Tools menu shows "Generate lazarusWeb Form Template".

> After upgrading to a new framework version or modifying design-time package source, you must redo the
> Compile → Install → restart IDE step for `lwdesign.lpk` in step 2, otherwise the designer and Tools menu still run old code.
> Do not compile `lwserver.lpk` in the IDE (nogui widgetset units are not in the IDE search path,
> will report `Can't find unit noguiint`); let the command line `lazbuild` or new project handle that package.
> See `docs/NOTES.md` pitfalls 15 / 16 for the complete pitfall record.

## Cross-Platform Build Matrix (Host → Target)

All source code (`src/`, `tools/`, `demos/`) is cross-platform: platform differences in core units
(timestamp precision / critical section reentrancy / path style, etc.) are isolated with `$IFDEF MSWINDOWS/LCLGTK2/LCLQT5`
and all have non-Windows branches; no Windows-specific units are referenced; all `.lpi`/`.lpk`
paths use forward slashes and do not hardcode target CPU/OS (artifact names use `$(TargetCPU)-$(TargetOS)` variables).

**FPC version**: The same source supports both **FPC 3.2.2 and 3.3.1**. The new capabilities of 3.3.1
(`fphttpserver` `RegisterUpdateHandler` / `ThreadMode` / `ConnectionHandler`)
and `SetTextAutoFlush`, `GetHTTPStatusText`, etc., are wrapped with `{$IF FPC_FULLVERSION >= 30301}`
dual branches; under 3.2.2, equivalent shims are used (OnRequest manually takes over upgrade, `select` self-implements
`LWCanRead`, built-in status code table, 1-byte text buffer), under 3.3.1 the native path is used, with consistent behavior.

Tested cross-compilation combinations (Windows host, nogui widgetset):

| Target | Command key points | Artifact |
|---|---|---|
| x86_64-linux | `--os=linux --cpu=x86_64 --ws=nogui --compiler=...ppcrossx64.exe` | `gallery_nogui-x86_64-linux` (ELF x86-64) |
| mips64el-linux | `--os=linux --cpu=mips64el --ws=nogui --compiler=...ppcrossmips64el.exe` | `gallery_nogui-mips64el-linux` (ELF MIPS, verified on Loongson 3A) |

```
lazbuild --os=linux --cpu=mips64el --ws=nogui \
         --compiler=/c/111/fpc/bin/x86_64-win64/ppcrossmips64el.exe \
         demos/gallery/gallery.lpi
# → gallery_nogui-mips64el-linux (ELF, ~6.5MB code segment; ld's abicalls
#   mixed-link warning can be ignored)
```

On a Linux host, just run `lazbuild` on each demo's `.lpi`; `build.sh` and
`build.bat` are functionally equivalent. Directory/file names are case-sensitive on Unix; see the next section for details.

## Directory Structure

| Path | Content |
|---|---|
| `src/core/lwbase.pas` | Common types, utilities, threadvar session pointer |
| `src/core/lwws.pas` | nogui widgetset patch (**required**, see below) |
| `src/core/lwform.pas` | `TLWForm` business form base class (includes `SendFile` / `SendText`) |
| `src/core/lwwriter.pas` | LCL control tree → JSON |
| `src/core/lwsession.pas` | Sessions, form list, synchronous modal |
| `src/core/lwdispatch.pas` | Browser events → real LCL control events |
| `src/core/lwhttp.pas` | HTTP service, static resources, API routing, upload/download |
| `src/core/lwapp.pas` | Application facade (register/command line/startup) |
| `src/core/lwconfig.pas` | Server configuration file (INI: Port / Theme / ExtDir) |
| `src/core/lwfileupload.pas` | `TLWFileUpload` upload button control |
| `src/core/lwcamera.pas` | `TLWCamera` capture control (mobile invokes system camera / desktop in-page viewfinder) |
| `src/core/lwdlg.pas` | **LCL dialogs redirected to browser** (ShowMessage / MessageDlg / InputQuery / TOpenDialog …) |
| `src/core/lwupload.pas` | multipart parsing and writing to disk |
| `src/core/lwdownload.pas` | Download token table (paths not exposed in URL) |
| `src/core/lwnewproject.pas` | Project skeleton template (shared by wizard and `lwnew`) |
| `src/client/lw.js` | Browser-side rendering and incremental reconciliation |
| `src/client/lw.css` | Base styles |
| `src/lwcore.lpk` | Runtime package (does not depend on widgetset, needed by design-time package) |
| `src/lwserver.lpk` | Runtime package (server side; automatically applies widgetset patch under nogui) |
| `src/design/lwdesign.lpk` | **Design-time package**: New Project Wizard / New Form / component palette |
| `demos/hello` | Minimal example |
| `demos/grid` | Table example (load/filter/edit/status bar) |
| `demos/multi` | Comprehensive example (menu/multi-tab/toolbar/**synchronous modal**) |
| `demos/db` | **SQLite database example** (TDBGrid/TDBEdit/TDBMemo CRUD, sorting, filtering, category statistics) |
| `demos/files` | **File upload/download example** (TLWFileUpload, SendFile, SendText export CSV) |
| `demos/dbaware` | **DB-aware control full set** (TDBText/TDBListBox/TDBRadioGroup/TDBLookup*/TDBImage data-aware testing; main form has 87 objects, `uAwareMain.lfm` 866 lines) |
| `demos/dialogs` | **Dialog example** (ShowMessage/MessageDlg/InputQuery/QuestionDlg/MessageBox/OpenDialog/SaveDialog) |
| `demos/gallery` | **Full-featured gallery** (benchmarked against uniGUI full-featured Demo: 12 pages, 60+ controls — standard controls/buttons/extended input/containers/grids/toolbars/charts/HTML·PDF·upload/dialogs/timers/DB-aware/large table pagination, `tests/t_gallery.py` 50-item regression) |
| `docs/MAPPING_en.md` | Control/property mapping table |
| `docs/CONTROL_MATRIX.md` | **Tested support matrix for 66 visual controls** (auto-generated) |
| `docs/DB_AWARE_MATRIX.md` | **Tested matrix for 12 DB-aware controls** (binding/display/sync/write-back, auto-generated) |
| `docs/SECURITY.md` | **Security notes**: SQL injection and trust boundaries (framework has no SQL channel, demo parameterized examples, business code self-check list) |
| `docs/NOTES.md` | nogui porting pitfall record, pitfalls 1–212 accumulated over time (important; old conclusions like pitfalls 23/66 have been revised by later pitfalls, refer to annotations) |
| `docs/HOW_IT_WORKS_en.md` | **Working principles in detail** (for first-time code readers: the complete round trip of one click, why full RTTI dump is not possible) |
| `docs/MANUAL.md` | **User manual** (usage + development) |
| `docs/FEATURES.md` | **Features and highlights** (one page to understand strengths and boundaries: eleven capabilities / seven decisions done right / number snapshot / comparison with uniGUI) |
| `docs/INDEX.md` | Documentation navigation index (find docs by scenario) |

## Quick Start

```
cd c:\LazarusWeb
build.bat                 :: Build all demos (lazbuild -B --ws=nogui)
build.bat grid            :: Build only demos\grid (project name auto-detected, db→dbdemo, files→filedemo)
demos\multi\multi.exe --port=8090
demos\db\dbdemo.exe --port=8095      :: SQLite CRUD example (requires demos\db\sqlite3.dll)
demos\files\filedemo.exe --port=8096 :: Upload/download example
demos\dbaware\dbaware.exe --port=8110 :: DB-aware control full set
start-gui.bat           :: Double-click to start GUI version (dbaware_gui.exe, see next section)
                           Linux/macOS: ./start-gui.sh
```

Open `http://127.0.0.1:8090/` in your browser. Command-line options:

```
--config=path         Specify configuration file (default auto-finds <exe-name>.ini / lazarusWeb.ini, see next section)
--port=8090           Listening port
--root=C:\LazarusWeb  Project root directory (contains src/client; ext-<version> only needed for optional Ext layer); defaults to current directory
--form=Name           Default form name
--client=ext          Browser rendering layer: ext | alpine; auto-detected if not specified (both prefer alpine)
                      Built-in default is ext; when deployed with alpine resources it auto-switches to alpine, explicit specification takes priority
--ext=7.0.0           Default Ext version (URL can also use ?ext=<version> to temporarily switch)
--extdir=directory    ext-js directory (equivalent of ExtDir config item)
--theme=crisp         Default theme (Ext rendering layer: classic/crisp/gray/material/neptune/graphite;
                      Alpine layer colors are not here, see below)
--title=title         Browser tab title (defaults to Application.Title)
--timeout=20          Session idle timeout (minutes)
--trust-proxy         Add when behind nginx/Caddy: client IP in logs takes X-Forwarded-For
--ssl                 Enable HTTPS (built into FPC; auto-generates self-signed cert if none given)
--ssl-host=name       Certificate hostname/SAN domain or IP, not listen address
--ssl-cert=file       Specify PEM certificate (paired with --ssl-key; relative path resolved from exe directory)
                      Providing cert/key automatically enables HTTPS, no need to write --ssl
--ssl-key=file        Specify PEM private key (paired with --ssl-cert)
--tls-cert= / --tls-key=  Aliases for the above two (providing them also auto-enables HTTPS)
--ajax-cors           Allow cross-origin calls to /lw/ajax/* (for third-party page integration)
--verbose             Print each request and exception stack
--nogui               Do not show server panel even in GUI build (service deployment)
--patch=1             Incremental patch (events return only changed ops, default off; old frontend auto-falls back to full)
--log=path            Append server logs to file
--pwa                 Enable PWA (manifest + Service Worker + installable + offline cache; off by default)
--pwa-name=name       Installed app name (defaults to --title=)
--pwa-short-name=name Home-screen short name (defaults to the first 12 chars of the name)
--pwa-theme=#RRGGBB   Browser toolbar color (default #1e88e5)
--pwa-bg=#RRGGBB      manifest background color (default #ffffff)
--pwa-vapid-public=   Web Push VAPID public key (push disabled if unset)
--pwa-vapid-private=  VAPID EC private key PEM path (relative paths resolved from exe directory)
--pwa-vapid-subject=  VAPID sub, e.g. mailto:admin@example.com
--pwa-push-token=     Token for /lw/pwa/push; requests must send X-LW-PWA-Token
--pwa-push-file=      Subscription store (default <root>\pwa-subscriptions.json)
--pwa-message-file=   Broadcast message file (default <root>\pwa-message.json)
--help                Help
```

The parameter table is aligned with the `--help` output of `src/core/lwapp.pas`; details (such as `--client` auto-detection) are subject to source code.

### Configuration File (INI)

If you don't want to type a long string of parameters every time, place an INI next to the exe (template at
[`lazarusWeb.ini.sample`](lazarusWeb.ini.sample)):

```ini
[lazarusWeb]
Port=8090
Theme=crisp
ExtDir=ext-7.0.0
;Patch=0
;Client=ext
```

| Item | Meaning | When empty/invalid |
|---|---|---|
| `Port` | Listening port | Uses default **8090** (warns if out of range) |
| `Theme` | Default theme (Ext rendering layer only, `?theme=` can still temporarily override); Alpine layer colors are selected in the title bar buttons, see `docs/MANUAL.md` §5.1 | Uses `crisp` |
| `ExtDir` | ext-js directory, absolute/relative paths both work | Auto-finds `<root>\ext-<version>` |
| `Patch` | Incremental patch switch, `1` = events return only changed ops | Default `0` (off) |
| `Client` | Browser rendering layer: `ext` / `alpine` (auto-detected if not written) | Auto-detect |
| `SSL` | Enable HTTPS: `1` / `true` / `yes` | Default `0` (HTTP) |
| `SSLHost` | Certificate hostname/SAN domain or IP; not listen address | Uses self-signed cert when empty |
| `SSLCert` | PEM certificate path (paired with `SSLKey`, relative path from exe directory) | Uses self-signed cert when empty |
| `SSLKey` | PEM private key path (paired with `SSLCert`) | Uses self-signed cert when empty |

Details (all decided after pitfalls):

- **Priority**: built-in defaults < configuration file < command line. `--port=9000` always wins over `Port=8090`,
  so "one exe copied ten times, each with an ini" and "temporarily change port for debugging" can coexist;
- **Where to place**: `--config=<path>` explicit; otherwise search in order
  `<exe directory>\<exe-name>.ini` → `<exe directory>\lazarusWeb.ini` →
  `<current directory>\<exe-name>.ini` → `<current directory>\lazarusWeb.ini`;
  relative path `--config=` is also allowed relative to exe directory (cwd is often System32 when started as service);
- **Format is very tolerant**: section name can be written or not (`[lazarusWeb]` / `[server]` / omitted all recognized),
  key names are case-insensitive and ignore `-`/`_` (`ext-dir` = `ExtDir`), values can be quoted,
  `;` and `#` at start are comments. Save file as UTF-8 or pure ASCII (ANSI Chinese paths will be garbled);
- **`ExtDir` is a "directory" not a "version number"**: given it, `/ext/<any version>/...` all served from this directory
  (one deployment usually carries one ext version); pointing to a non-existent or empty directory warns and auto-falls back to
  `<root>\ext-<version>`, will not prevent service from starting;
- Startup banner prints the actual configuration file path and ext directory; check these two lines first when troubleshooting.

Write your own Web program (the server side is only this much code):

```pascal
program myapp;
uses Interfaces, Forms, lwapp, uMain;
begin
  Application.Initialize;
  TLWApp.Register(TMainForm);   // Class name minus T is the form name in browser
  TLWApp.Run;                   // Automatically calls LWInstallWidgetSet
end.
```

The only line to change in the form unit:

```pascal
uses ..., lwform;
TMainForm = class(TLWForm)   // Originally class(TForm)
```

> **Important**: Compilation must include `-B` (`lazbuild` does not record `.lfm` in the dependency table,
> old `.o` will continue to be used when only changing UI without changing `.pas`).
> `build.bat` already has this added.

## Deployment (Running in Standalone Directory)

The framework **supports** copying the `ext-<version>` directory to the application's own directory for self-contained deployment. When `--root=` is not passed, the root directory is determined in the following order:

1. **Current working directory** — as long as there is an `ext-<version>` directory in that directory, it is considered
   the root. Use whichever directory it is started from, most intuitive.
2. **Up to 5 levels up from the executable directory** — find a directory where both "`ext-<version>` + `src/client/lw.js`
   exist" (fallback for double-click run or starting from elsewhere).
3. Neither found → `C://LazarusWeb`.
4. Explicit `--root=<path>` has highest priority, overriding the above three.

`/lw/lw.js`, `/lw/lw.css` (and alpine's `/lw/lw-alpine.js`, `/lw/lw-alpine.css`,
`/lw/alpine.min.js`) lookups all have multi-path fallback; the following layouts all work:

| Layout | Required files (take one set per rendering layer) |
|---|---|
| Standard repository layout (recommended) | `<root>/src/client/lw.js`, `lw.css`; or `lw-alpine.js`, `lw-alpine.css`, `alpine.min.js` |
| Flat deployment | Above files in same directory as exe |
| Semi-flat | Place above files under `<exe directory>/lw/` or `<root>/lw/` (old deployment's `<root>/client/` still compatible) |
| Fallback | Search upward from root for same-named files under `src/client/` |

Minimal self-contained deployment directory (**default Alpine.js rendering layer, no ext directory needed**):

```
MyApp/
  MyApp.exe
  src/client/alpine.min.js   44 KB   Alpine.js itself (defer loaded, not from CDN)
  src/client/lw-alpine.js    205 KB  Renderer/coordinator (adaptive for this layer only; templates shared by both layers)
  src/client/lw-alpine.css    59 KB  Styles: CSS variables for 7 color schemes (light/beige/eye-care green/high contrast/dark/dark blue/ink green) all here
  tpl/                              Optional: form templates; read by both Alpine/Ext layers, silently falls back to design-time layout when missing
  favicon.ico                       Optional: browser tab icon (can be placed in exe directory or --root directory)
  ext-<version>/                    Optional: Ext JS rendering layer (~75MB, requires explicit --client=ext switch)
  cert/                             Optional: place server.crt/server.key/ca.crt when SSL is on and using own PEM
  libssl-3-x64.dll + libcrypto-3-x64.dll  Optional: must be placed in exe directory when SSL is on
```

(When using Ext rendering layer, replace with `src/client/lw.js` + `lw.css` + `ext-<version>/`;
all three alpine files are required—missing `alpine.min.js` makes auto-detection judge alpine unavailable and
fall back to ext; missing css makes the page run but with no styles at all.)

Verify: after startup, check the `Root :` and `Client :` lines in the banner (default should be alpine), or
`curl -o /dev/null -w "%{http_code}" http://127.0.0.1:8090/lw/lw-alpine.js` (should be 200).

### Starting Demos

```bat
start-demo.bat            :: Default 8092, double-click to run
start-demo.bat 8095       :: Specify port
```

```bash
./start-demo.sh           # Linux / macOS, default 8092
./start-demo.sh 8095
```

The service runs in the foreground; open the address shown in the browser, `Ctrl+C` or close the window to stop.
(If the port is occupied, change to another: after a process is forcibly killed, an orphan socket with `LISTENING PID 0` may remain,
visible in `netstat` but cannot be killed; changing port is easiest.)

## Cross-Platform (Linux / macOS)

Core units only use FPC/LCL general facilities: `fphttpserver`, `SysUtils`'
`DirectoryExists`/`FileExists`/`ExtractFileDir`, and `PathDelim` /
`IncludeTrailingPathDelimiter` for path concatenation — **no** `Windows`, `winsock`,
`ShellExecute` or similar platform units (`grep -rn "Windows" src/core/*.pas` only hits in
comments). `lwws.pas` degrades to empty implementation under non-nogui widgetsets, so it can also compile
under win32/gtk2/qt5/carbon (running still recommends `--ws=nogui`).

Build:

```bash
./build.sh                        # All demos
./build.sh dbaware                # Single
LAZBUILD=/opt/lazarus/lazbuild ./build.sh

tools/build.sh                    # All tools (convert/hyper/audit/dbcheck/hyper_gui/convert_gui)
tools/build.sh convert            # Single tool (fpc direct compile, no LCL)
tools/build.sh hyper_gui          # GUI tools compiled with host widgetset
```

`.lpi` does not fix `TargetOS`/`TargetCPU`, builds according to host platform; on Unix artifacts have no
`.exe` suffix (`build.sh` will delete both names). Windows uses `build.bat`,
`LAZBUILD` environment variable can also override.

Runtime dependency differences:

| Dependency | Windows | Linux | macOS |
|---|---|---|---|
| SQLite (demo use) | `sqlite3.dll` (demo directory already has) | `libsqlite3.so` (`apt install libsqlite3-0`) | System built-in |
| Alpine.js / lw-alpine.js (default); Ext JS / lw.js (optional) | Same as left | Same as left (paths concatenated by `PathDelim`) | Same as left |
| Command-line parameters | `--port=` `--root=` `--theme=` `--config=` | Same as left | Same as left |

Note that Unix filenames are case-sensitive (Windows is not); keep directory/file names like `src/client`
as-is (ext directory name can be arbitrary; server will auto-identify the unique `ext-*` directory under root).

## Creating Projects in the IDE with the Wizard (Design-Time Package `lwdesign`)

After `src/design/lwdesign.lpk` is installed, three additional things appear in Lazarus:

| Location | Content |
|---|---|
| File → New → Project | **lazarusWeb** template; after selecting, three dialogs pop up in sequence: ① application mode (normal / **service (daemon)**; service mode additionally generates `uDaemon.pas`/`uMapper.pas`/`lazarusWeb.ini`, see `docs/SERVICE_NAMING.md`); ② project type (`lazarusWeb project` GUI debug build / `lazarusWeb project(nogui)` deployment build); ③ project template (regular / plugin). Disk write timing matches Lazarus built-in templates: after selecting the three dialogs nothing is written (project is "virtual"); the "Save Project" dialog only pops up when saving (Ctrl+S). Directory defaults to the IDE option's "project build test directory". This step generates `.lpr/.lpi/umain.pas/.lfm/build.bat/build.sh/favicon.ico`, and copies the framework's `src/client` to the project directory's `lw/` (runtime finds static resources as `exe/lw/<file>`; site icon `favicon.ico` goes in project root, server finds it in order of `<root>` → `<exe directory>`). The nogui build's `.lpi` macros are only written **after the save transaction truly ends** (`.lpi` and all units on disk, two consecutive stable rounds before acting; never pop up dialogs or reload project during save, see NOTES pitfall 172), so **about 1 second after saving** they are completed, and a message "nogui build: effective after reloading project" pops up—click "Yes" to reopen the project, F9 gives a windowless console service |
| File → New → File | **lazarusWeb Form** — a `TLWForm` form unit, directly into designer |
| Component palette | **lazarusWeb** page: `TLWFileUpload` / `TLWCamera`, etc. |

Install (only once):

```
tools\install_design.bat        :: Register the four packages first (lwcore / lwserver / lwvst / lwdesign)
```

Then follow its prompts in the IDE: `Package → Open Package File → lwdesign.lpk → Use → Install`,
let the IDE rebuild once (design-time package is statically linked into `lazarus.exe`, must rebuild to take effect).

First time use, five steps:

1. **Install packages**: the one-line command above + `Install` to rebuild the IDE (reinstall when upgrading packages, otherwise it runs old code);
2. **New**: `File → New → Project` select template (GUI build debug / nogui build deployment), after selecting **nothing written**;
3. **Save**: `Ctrl+S` pops up standard "Save Project" dialog to write. Do not name the project `LWApp` (conflicts with `lwapp.pas`, compile reports `Duplicate identifier "LWAPP"`); default `LWApp1` is safe;
4. **nogui build extra step**: about 1 second after saving, "nogui build: effective after reloading project" pops up, click **"Yes"**;
5. **F9**.

> **Note: Pressing F9 within 1 second after saving still uses win32 widgetset** — macros have just been written into the `.lpi`
> file, IDE memory's project options have not been re-read, so it will still pop up the server panel window. Wait for the
> prompt in step 4 and click "Yes" before F9; if you don't want to reopen the project, use the
> `build.bat` in the project directory to compile.

Disk file list, UI details of each step, and troubleshooting (`%TEMP%\lazarusweb-wizard.log`) are in
`docs/MANUAL.md` "Creating Projects with the IDE Wizard (Building from Scratch)".

> TLWForm is a **real TForm descendant**, not a shadow class like uniGUI, so no design-time proxy is needed:
> TButton/TEdit dragged on are LCL's own controls; property panel, event page, alignment tools, anchors all work as usual,
> the layout seen in the form designer is the layout in the browser.

If you don't want to open the IDE, you can also directly generate project skeleton from the command line (this generates a Lazarus project, not a form template; use the IDE Tools menu above for template skeleton):

```
tools\lwnew.exe --name=DemoApp --dir=C:\work\DemoApp --units=C:\LazarusWeb\src\core
```

`--units` specifies source directory without depending on installed packages; omitting it requires the `lwserver` package to be registered.

**Compilation method**: Which widgetset LCL uses is determined by the `LCLWidgetType` macro in `.lpi`.
Demos in the repo and manually converted old projects do not have this macro; in the IDE, F9 will use the IDE's own
widgetset (win32), cannot link to LCL's nogui units, only can specify via lazbuild; the wizard-generated
nogui project already writes this macro into `.lpi`, so after reloading the project, F9 in the IDE is directly
nogui (within 1 second after saving, F9 will still be win32, see previous section). `build.bat` writes both:

```
lazbuild -B --ws=nogui <project>.lpi
```

> Note the distinction: **packages** (`lwserver.lpk`) can be compiled/installed directly in the IDE — `lwws.pas`'s
> nogui patch is wrapped with `{$IFDEF LCLnogui}`, degrading to empty implementation under non-nogui;
> but **projects without the `LCLWidgetType` macro** (demo, manually converted old projects) must
> `--ws=nogui`, see `docs/NOTES.md` pitfall 15.

## File Upload / Download

Upload uses `TLWFileUpload` (a `TButton` descendant, can be placed at design time):

```pascal
procedure TFileForm.btnUploadUpload(Sender: TObject; const AFileName: string);
begin
  // AFileName is the full path on the server, directly open with TFileStream
  lstFiles.Items.Add(ExtractFileName(AFileName));
end;
```

- Browser pops up system file dialog, XHR upload with progress, button text shows percentage in real time;

## Capture (TLWCamera)

`TLWCamera` (a dedicated descendant of `TLWFileUpload`) can be dragged onto the form:

```pascal
procedure TMainForm.camPhotoCapture(Sender: TObject; const AFileName: string);
begin
  // Photo already on server disk (%TEMP%\lw_uploads\<session>\camPhoto\xxx.jpg)
end;
```

- Mobile/tablet: Clicking the button directly invokes the **system camera** (`Facing` switches front/rear), after shooting goes through existing
  upload channel and triggers `OnCapture`; **works over LAN http**;
- Desktop: Under HTTPS or localhost, pops up **in-page viewfinder** (getUserMedia, live view +
  capture/cancel/select image), captured frame compressed to long edge 1600px, converted to JPEG, goes through same channel;
  Desktop pages over LAN http are prohibited by browser from accessing camera, automatically degrades to "Select image file";
- Preview: `PreviewImage := 'imgPhoto'` — after browser captures, immediately displays locally to specified
  TImage; photo data does not go through component tree patch; server only gets file path;
- Full description in `docs/MANUAL.md` usage section "Capture", example
  `demos/mobile_demo`, regression `tests/cdp_camera.py`.
- Server parses `multipart/form-data`, writes to
  `%TEMP%\lw_uploads\<session number>\<control name>\` (or specify with `TargetFolder`);
- Filenames are sanitized (remove path, remove `..`, remove illegal characters), multiple selection triggers `OnUpload` one by one;
- `Filter` (`'Text|*.txt;*.csv|All|*.*'`), `Multiple`, `MaxSizeKB` all participate in validation.

Download is one line in business code:

```pascal
SendFile('C:\data\report.xlsx');              // Push existing server file
SendText(csv.Text, 'list.csv', True);       // Direct download of computed text (True = with BOM, Excel recognizes Chinese)
```

The URL **will not** contain server paths: `SendFile` registers the file as a one-time token,
browser only gets `/lw/download?t=<token>`, token expires after 30 minutes or first use.

| Route | Description |
|---|---|
| `POST /lw/api/upload?sid=&id=` | `multipart/form-data`, returns new component tree |
| `GET /lw/download?t=<token>` | With `Content-Disposition` (including `filename*=UTF-8''`) |

**Complete business example**: `demos\db` attaches attachments to each product (upload → write to
`attachments\item<id>\` + write `attachments` table → download/delete),
uses separate database connection for attachment writes, does not interrupt the main record being edited — see
`demos\db\README.md` "How attachments are wired".

## Dialogs (ShowMessage / MessageDlg / TOpenDialog …)

**Not a single line of business code needs to change**. LCL's functions are redirected on the server to "pop up modal in browser",
the server thread hangs there waiting for the user to click, then continues:

```pascal
procedure TMainForm.Button1Click(Sender: TObject);
begin
  if OpenDialog1.Execute then              // Browser pops up file selection
    mmoLog.Lines.Add(OpenDialog1.FileName); // Returns server temporary path
  ShowMessage('lazarus Web test');            // Browser pops up message box
end;
```

Directly usable (no code, no replace):

| LCL entry | What you see in browser |
|---|---|
| `ShowMessage` / `ShowMessagePos` | Iconless message box + OK |
| `MessageDlg` / `MessageDlgPos` | Icon per `TMsgDlgType`: info/warning/error/question |
| `InputQuery` / `InputBox` / `PasswordBox` | With input box (`PasswordBox` is password box) |
| `QuestionDlg` | Custom button text, `ModalResult` returned as-is |
| `Application.MessageBox` / `LCLIntf.MessageBox` | `MB_YESNO` etc. flags parsed per Windows semantics |
| `TOpenDialog.Execute` | Select file (**first upload to server**), `FileName` = server path |
| `TSaveDialog.Execute` | Enter filename, `FileName` = path in session temp directory |

Things you must know:

- **File dialogs get server paths**. Browser cannot give local paths to server,
  so selected files are uploaded via `multipart` to `%TEMP%\lw_uploads\<session number>\pick\`,
  `FileName` is that path, `TFileStream` can open and read directly. Saving is the same:
  `TSaveDialog.FileName` falls in `...\<session number>\save\`, after writing file you `SendFile` to push to user for download.
- **Thread will really block**. Event request hangs until user replies (or 180-second timeout), then returns,
  consistent with desktop modal behavior; other sessions continue running, popping a second dialog in same session is rejected with a message.
- **When no browser session** (e.g., F9 debug directly in IDE, or running unit tests from command line) automatically falls back to LCL original implementation.
- These are **runtime replacements**, `lwdlg.pas` is in `lwcore` package, effective when business project `uses lwapp`
  (`LWInstallDialogs` installed before `TLWApp.Run`, hooks `InterfaceBase`'s
  `PromptDialogFunction` / `InputDialogFunction` / `QuestionDialogFunction` /
  `Forms.MessageBoxFunction` and `RegisterWSComponent(TOpenDialog, …)`).

**Complete example and HTTP-level tests**: `demos\dialogs` (7 buttons each demonstrate one),
`tests\t_dialog.py` (36 items, including "push → reply → wake → return value" full chain).

## Runtime Behavior (Correspondence with uniGUI)

| uniGUI | lazarusWeb |
|---|---|
| TUniSession | TLWSession (one per browser tab) |
| Component → JS mapping | lwwriter + lw.js incremental reconciliation |
| Synchronous modal (nested message loop) | `ShowModal` pushes instruction then suspends request thread, `TEvent.WaitFor` waits for browser close |
| Ajax event | `POST /lw/api/event`, value first written back to control then RTTI triggers event |

Business code is completely unaware of the Web:

```pascal
procedure TMainForm.miAboutClick(Sender: TObject);
var f: TAboutForm;
begin
  f := TAboutForm.Create(nil);
  try
    if f.ShowModal = mrOk then          // Under Web this line waits for user to click OK
      lblState.Caption := 'Viewed About';
  finally
    f.Free;
  end;
end;
```

## HTTP API

| Route | Description |
|---|---|
| `GET /` | UI shell (`?ext=7.0.0&form=MainForm` can override defaults; `?fresh=1` forces new session) |
| `POST /lw/api/session` | Create session `{form:"MainForm"}` → returns tree + `sid` + `seq` |
| `GET /lw/api/attach?sid=` | **Cross-tab sharing**: attach this tab to existing session (returns 410 + `gone` if not exists) |
| `GET /lw/api/tree?sid=` | Current component tree |
| `POST /lw/api/event` | `{sid,id,ev,val,row,col,vals,tab}` → new component tree |
| `GET /lw/api/poll?sid=&t=&after=` | Long polling. With `after` fetches pushes by cursor (each tab fetches its own); without is old destroy-style queue. **The only push channel** |
| `GET /lw/ws?sid=` | WebSocket upgrade (RFC6455): **only carries event requests/responses** (events go through WS frames when WS connected); pushes do not go through WS, always delivered by long-poll cursor above, auto-falls back to HTTP on disconnect |
| `GET /lw/api/log?sid=` | Session log (Show/ShowModal/EndModal all recorded) |
| `POST /lw/api/close` | End session |
| `POST /lw/api/dlg` / `POST /lw/api/dlgfile` | Browser modal (ShowMessage/MessageDlg/InputQuery/TOpenDialog…) reply endpoints (see `docs/MAPPING_en.md` dialog section) |
| `POST /lw/api/upload?sid=&id=` | File upload (`multipart/form-data`, any field name, multiple files allowed) |
| `GET /lw/download?t=` | Download (`t` is one-time token registered by `lwdownload`, discarded after use) |
| `GET /lw/ajax/<name>` | **Custom AJAX endpoint**: registered by `TLWApp.AddAjax(name, handler)`, third-party JS can fetch directly |
| `GET /lw/healthz` | Health check (LB/k8s probe): `{"ok":true,"sessions":..,"uptime":..}` |
| `GET /ext/<version>/<path>` | Ext JS static resources (two versions coexist) |
| `GET /favicon.ico` | Site icon: `--root` directory → exe directory → 204 if neither; 200 + `Cache-Control: public, max-age=86400` on hit. Both shell HTML heads have `<link rel="icon">` |

## Control Support (Tested)

`docs/CONTROL_MATRIX.md` is auto-generated by `tools\lwaudit` (snapshot: 2026-11-09,
fixes after that date see `docs/NOTES.md` pitfalls 97/107): 66 commonly used LCL
visual controls are **really created + attached to form + serialized once** under nogui, then cross-checked against `lw.js`
to see if there is a real rendering branch, divided into five categories:

| Status | Meaning | Current count |
|---|---|---:|
| ok | Browser renders as real control, bidirectional events work | 49 (74.2%) |
| placeholder | Server side usable, browser draws a box with class name | 14 |
| kind-only | kind mapped but missing rendering branch | 1 |
| create-failed | Throws exception on construction under nogui (e.g., native `TDBNavigator` depends on button glyphs, use `TLWDBNavigator` instead, see pitfalls 29/41) | 1 |
| render-failed | Construction succeeds but serialization/rendering crashes (e.g., `TDateEdit` NullDate, pitfall 107 already has fallback) | 1 |

Latest classification is subject to `docs/CONTROL_MATRIX.md`; this table is overview only.

There are also 16 non-visual components (`TTimer`/`TOpenDialog`/`TDataSource`/`TMainMenu`…)
directly usable on server side, not participating in rendering statistics.

## Mobile (Phone / Narrow Window)

Alpine rendering layer has built-in mobile adaptation, **zero business code changes**: viewport ≤834px automatically enters
mobile layout (≥1100px exits, hysteresis in between prevents jitter), phones/tablets/desktop narrow windows all auto-adapt:

- **No template**: Form renders at design size (font not shrunk), parts beyond screen scroll
  to pan and view—usable, but not a small-screen optimized layout;
- **With template**: Write an HTML template for the form (`{%control-name%}` placeholder references control Name,
  browser moves existing control DOM into template for flow layout), events and incremental patches as usual, automatically switches
  between breakpoints without losing state; change template and refresh takes effect, no recompile needed:
  - Mobile `<root>\tpl\<form-name>.m.html` — phone single-column layout, form fills viewport;
  - Desktop `<root>\tpl\<form-name>.html` — custom desktop layout (centered card,
    two columns, etc.), **form position and size stay at design time**, only client area content becomes flow;
- Manual switch: URL `?layout=mobile|desktop` or `LW.layout.set()`;
- **One-click template skeleton generation**: After installing design-time package `lwdesign`, the IDE **Tools menu**
  has an extra item "Generate lazarusWeb Form Template (Current Unit LFM)"—generates **desktop + mobile** two
  template skeletons to `<project directory>\tpl\` from the currently open form's .lfm (including
  `{%control-name%}` placeholders, basic CSS with per-control fixed height from design time, main area filling form
  stretches by **container** height `calc(100% - other controls)` (desktop accumulates by row, mobile single column adds directly;
  not `100vh` — client area is smaller than viewport when form is opened in a floating window), asks individually before overwriting existing),
  generates self-check report (skipped non-visual controls, duplicate/illegal placeholder names, nested containers, main area
  changes); after generation copy to runtime root (or directly effective when project directory is runtime root), refresh to see;
  see `MANUAL.md` 16.0; ready-made example `demos\mobile_demo\tpl\` (manually adjusted proportions),
  generator itself uses `demos\gallery` and `demos\dbaware` real forms for parsing and size
  regression (the latter covers main form in floating window, login page without main area, top toolbar row + PDF main area);
- **Capture upload**: `TLWCamera` control (drag from component palette to use)—mobile clicking button invokes
  system camera, auto-uploads to server after shooting (`OnCapture`), browser local instant preview;
  LAN http works (no HTTPS needed), see README "Capture (TLWCamera)" section;
- Usage see `docs/MANUAL.md` usage section "Mobile", template development guide see
  `MANUAL.md` Part Two "16. Form Template Development Guide (Desktop + Mobile)", mechanism and
  testing see `docs/MOBILE_en.md` §8, runnable example `demos/mobile_demo`
  (same form configured with desktop + mobile templates).

## Known Limitations

- Single-form applications default to one thread per session request on a port; other requests in that session during modal are queued on event queue (consistent with desktop modal semantics);
- Modal timeout `LW_MODAL_TIMEOUT_MS = 180000` (3 minutes);
- Only one dialog at a time: nesting a second dialog in same session is ignored (browser cannot overlay two modals);
- `TOpenDialog` does not read server directory list — browser selection box can only "upload file", cannot browse server disk;
  to select files on server, build your own UI with `TListView`/`TShellListView` etc.;
- Unadapted controls show gray box placeholder in browser (server side alive as usual), does not affect other controls;
  specific list see `docs/CONTROL_MATRIX.md`;
- `TSplitter` only draws divider, **does not support dragging**; `TProgressBar` / `TTrackBar` /
  `TUpDown` browser-side adjustments write back to server (`TUpDown` up/down arrows also link
  Associate edit box, see `docs/NOTES.md` pitfall 152);
- High DPI only processed as virtual display 96 DPI (`lwws.pas` constant can be changed);
  Forms designed on Windows at 125%/150% scaling (lfm `DesignTimePPI=120/144`)
  are automatically scaled back to 96 DPI on creation (geometry + font together, driven by `Application.Scaled`,
  see `docs/NOTES.md` pitfall 18).

## Database Applications (TDBGrid / TDBEdit + SQLite)

`demos/db` is a complete CRUD example, `demos/dbaware` is **DB-aware control full set**
(12 data-aware controls laid out on one page, support see `docs/DB_AWARE_MATRIX.md`).
DB controls bind directly to `TDataSource`, behavior in browser is consistent with desktop programs: click row to locate,
edit field, Post / Cancel / Delete / Locate.

| DB control | Support |
|---|---|
| TDBGrid / TDBEdit / TDBMemo / TDBComboBox | Complete (browse + write-back) |
| TDBCheckBox | Complete (binding 0/1 field must set `ValueChecked`/`ValueUnchecked`) |
| TDBListBox / TDBRadioGroup / TDBLookupComboBox / TDBLookupListBox | Complete (return selected item/key value and write back to field) |
| TDBText / TDBImage | Read-only (text / PNG image follows field in real time) |
| TDBNavigator | Complete. lfm must write real class name `TLWDBNavigator` and `RegisterClass(TLWDBNavigator)`—`RegisterClassAlias` cannot replace already registered `TDBNavigator` (pitfalls 29/41 have overturned old scheme); code side can also use `LWNewNavigator` factory |

Three hard rules (see `docs/NOTES.md` for details):

1. **SQLite string columns always use `VARCHAR(n)`** — `sqlite3conn` maps `TEXT`/`CHAR`
   to `ftMemo`, DBGrid only displays `(MEMO)`;
2. **`sqoAutoApplyUpdates` only sends SQL, does not commit transaction** — clicking "Save" in browser looks
   successful, but actually hangs in uncommitted transaction: all rolls back when program exits, another session writing gets
   `database is locked`. After Post/Delete must explicitly `SQLTransaction.Commit`;
   add `Params.Add('journal_mode=WAL')` + `PRAGMA busy_timeout=10000` to connection,
   `CommitRetaining` before writing to discard old read snapshot (WAL's `SQLITE_BUSY_SNAPSHOT`
   is not governed by busy_timeout). Complete method see `docs/NOTES.md` pitfall 9.2;
3. **Framework does not send grid rows while dataset is in edit state** (moving cursor triggers auto Post),
   browser uses last data, auto-refreshes after save/cancel.

## Reports (Print / Export)

`src/core/lwreport.pas` is the server-side report engine: one report definition (title + columns + summary +
paper), shared by three outlets:

| Outlet | Description |
|---|---|
| Printable HTML | A4 `@page`, `@media print`, `thead` repeated per page, zebra stripes, total row; preview page has built-in "Print / Save as PDF" buttons |
| CSV | UTF-8 BOM + CRLF, Excel / WPS double-click no garbled |
| XLSX | Real OOXML (`zipper` packaging, no third-party library dependency): header style, freeze panes, column width, total row |

`demos/dbaware`'s "Report Center" form is a complete example: data source switching, preview (iframe +
view token), click "Print…" with `#print` auto-pops print dialog, guest account disables export.

```pascal
rpt := TLWReport.Create(nil);
rpt.DataSet := FQry;
rpt.Title := 'Inventory Large Table Details';
rpt.Columns.AddCol('Code', 'code', 30);
rpt.Columns.AddCol('Amount', 'amount', 34, taRightJustify, rsSum);
rpt.SaveHTML(fn);   // Or SaveCSV / SaveXLSX
```

## Custom AJAX Endpoints (Third-Party JS Integration Escape Hatch)

When you want to embed your own JS / third-party component library in the page and bypass the component tree protocol to get data directly, use
`TLWApp.AddAjax` to register an endpoint with any name (name case-insensitive, `/` allowed):

```pascal
TLWApp.AddAjax('items/price',
  function (Ctx: TLWAjaxContext): Boolean
  begin
    Ctx.Json('{"price":299.00}');    // Or Ctx.Text(...) / Ctx.Error(...)
    Result := True;
  end);
```

Browser side directly `fetch('/lw/ajax/items?limit=3')`, cross-page integration add
`--ajax-cors` startup parameter. Context object provides `Param()/Header()/JSONBody()/
FormField()` and `Session` (`?sid=` or `X-LW-Sid` header, can read session-level data).
Complete example: `demos/dbaware/uAjax.pas` (items / items/price / whoami / echo four endpoints,
main form "Charts/Other" tab has a native HTML frame that directly fetches them).
Unregistered names return 404 and list all available endpoints for introspection.

## Cross-Tab Session Sharing

The second tab in the same browser no longer "starts a new session and logs in again": sid is stored in
`localStorage`, new tab first `GET /lw/api/attach?sid=…` to attach to existing session
— login identity, opened forms, server data all there, directly see main form.

- Pushes (modal / message box / mask / download instructions…) uniformly enter session queue with sequence numbers, each tab uses
  `/lw/api/poll?after=N` to fetch its own, mutually non-consuming;
- Dialog instructions carry `to=<tab identifier>`, only the tab that initiated the event pops up, other tabs do not re-pop;
- Any tab's operation (open form / close form / mask) syncs to other tabs in real time;
- When session expires / service restarts returns 410, browser automatically discards old sid, creates new session, returns to login page;
- `?fresh=1` forces new session (for multiple people sharing one browser, debugging).

Regression: `tests/t_multitab.py` (22 items) + `tests/cdp_multitab.py` (CDP dual real tabs 6 items).

## GUI Server Panel

Each demo has two builds (using dbaware as example):

| Build method | Artifact | Form |
|---|---|---|
| `dbaware.lpi` (default, `--ws=nogui`) | `dbaware.exe` | Console subsystem: large black terminal prints logs in real time, for tests/CI |
| `dbaware_gui.lpi` (win32 + `-WG`) | `dbaware_gui.exe` | **GUI subsystem**: double-click to run, only a small panel window |

GUI version starts with a server panel (benchmarked against uniGUI standalone server's window):

- Title `lazarusWeb 0.9.6 Standalone Server - Port <N>`;
- Menu "File": Open browser (F5) / Copy access address / Exit;
- Menu "Manage": Clear log / Toggle verbose log (verbose) / About;
- Middle is scrolling log area (startup banner + session creation + request logs, limited to 4000 lines);
- Status bar three cells: Listen address / Online session count (refreshed per second) / Uptime;
- **System tray**: persistent tray icon (blue background "LW"), clicking X only hides to tray (first time pops
  balloon reminder), left-click icon restores panel, right-click menu: Open panel / Open browser / Exit;
- **Only menu "Exit" truly stops the service** (graceful stop ~0.3s: wakes suspended long polling,
  disconnects keep-alive connections, accept loop exits within 250ms, see NOTES pitfall 44).

Command-line parameters take effect for both builds: `--nogui` (GUI build falls back to windowless mode,
for service deployment), `--log=path` (log to disk). Logs uniformly go through `lwrlog` unit:
console build writes to console, GUI build writes to panel, both can also write to file simultaneously.

To make your own program a GUI version, just copy `demos/dbaware/dbaware_gui.lpi`:
The only difference from a normal `.lpi` is the `LCLWidgetType=win32` macro +
`-WG` compile option + target name with `_gui` suffix. Note that `.lpr` should not write
`{$APPTYPE CONSOLE}` (it overrides command-line `-WG`).

## Deployment (HTTPS / Reverse Proxy / Cluster)

There are two paths for HTTPS, both zero code changes:

1. **Use FPC's built-in TLS directly (recommended, no proxy needed)**: Add `--ssl` to business exe or
   `lwhyper`, same port changes from HTTP to HTTPS; auto-generates
   self-signed cert if none given. Requires bundling `libssl-3-x64.dll` + `libcrypto-3-x64.dll`.
   For cluster scenarios enable at lwhyper outer layer, workers still use plaintext between them.
2. **Front reverse proxy**: nginx / Caddy terminates TLS, exe stays HTTP. Complete guide and
   ready-made configuration see **`deploy/README.md`**, [`deploy/nginx.conf`](deploy/nginx.conf),
   [`deploy/Caddyfile`](deploy/Caddyfile).

`--ssl-host` is filled with **certificate hostname** (domain/IP in browser address, must match certificate SAN),
not listen address. For non-self-signed certificates from formal CA or private CA, command-line examples and intranet
CA generation steps see `deploy/README.md` §1.1; only when both parameters are empty is self-signed cert auto-generated.

Key points:

- Add `--trust-proxy` when starting exe behind proxy (IP in logs is then real client IP);
- nginx's `/lw/ws` location must have `Upgrade`/`Connection` headers (WebSocket),
  otherwise silently degrades to long polling;
- Cluster = same exe multiple ports + **sticky sessions** (nginx `ip_hash` /
  Caddy `lb_policy ip_hash`): sessions in process memory, not sticky means "lost session";
- Health check uniformly hits `/lw/healthz` (pure memory read, returns online session count and uptime);
- After instance downtime failover, browser receives 410 and auto-creates new session returning to login page (fallback chain already implemented).

## Dedicated Load Balancer lwhyper (Benchmarked Against uniGUI Hyper Server)

When you don't want to install nginx, use `tools/lwhyper.exe` one process to handle the cluster (counterpart of uniGUI Hyper Server):
starts N workers (same business exe multiple instances), auto-restarts on crash, external single port
reverse proxy, session stickiness by sid, WebSocket TCP-level passthrough, built-in health monitoring.

```
:: Compile (once)
lazbuild -B --ws=nogui tools\lwhyper.lpi

:: Start: 2 workers (dbaware.exe multiple instances), external listen 8080
tools\lwhyper.exe --port=8080 --workers=2 --exe=demos\dbaware\dbaware.exe
```

If you don't want to remember parameters, use GUI version `tools\lwhyper_gui.exe` (Windows uses
`tools\build_hyper_gui.bat` to compile, Linux/macOS uses `tools/build.sh hyper_gui`):
fill in business exe / port / worker count in the window, click "Start", panel has worker
detail table (port/PID/sessions/restarts), real-time logs and persistent tray (click X to hide, right-click to exit).
GUI version and console version share `src/core/lwhyper.pas`, proxy behavior is completely identical.

Browser directly opens `http://127.0.0.1:8080/`, no difference from direct single instance. Parameters:

```
--port=8080          Listen port (worker default port+1 sequential)
--workers=N          Number of worker processes (default 2)
--exe=path           Business exe (required)
--base-port=N        First worker port
--root= / --theme=   Forwarded to worker
--worker-args="..."  Appended verbatim to worker command line (e.g., --trust-proxy)
--logdir=directory   Worker log directory (default <TEMP>\lwhyper)
--ssl                Outer layer HTTPS; workers still use HTTP
--ssl-host=name      Certificate hostname/SAN domain or IP; use self-signed cert when empty
--ssl-cert=file      Specify PEM certificate (paired with --ssl-key); providing it auto-enables HTTPS
--ssl-key=file       Specify PEM private key (paired with --ssl-cert)
--tls-cert= / --tls-key=  Aliases for above two (providing them also auto-enables HTTPS)
--hot-update         Hot update (default on): monitor new version exe, roll restart workers after shell swap
--no-hot-update      Turn off hot update
--update-dir=directory  New version drop directory (place file same name as business exe; default sees <exe>.new)
--verbose            Print each proxy request and probe
```

**Hot update (zero-downtime version swap)**: After compiling, copy new exe as `<business-exe>.new` (or throw into
`--update-dir`), lwhyper decides after about 4 seconds and swaps shell, and **one by one** restarts workers
(at least N-1 serving at any moment); if new version fails to start, auto-rolls back and keeps `.bad-<time>`.
Stopping workers uses graceful exit (worker side `POST /lw/shutdown` + token), not forced kill.
Mechanism and usage see `docs/WHYPER.md` §5.1 (usage) / §5.2 (implementation).

Own endpoints: `/lw/healthz` (aggregate probe), `/lw/hyper/status` (worker details:
port/pid/alive/session count/restart count/sticky session count).

How it works and boundaries:

- **Sticky**: sid on each API call (`?sid=` / `X-LW-Sid`), new sessions round-robin assigned,
  then lookup table sticks to same worker; after lwhyper restart loses table, requests with unknown sid round-robin forwarded,
  worker returns 410 → browser auto-rebuilds session (fallback chain existing);
- **Worker crash**: auto-restart within 2-second probe cycle (`restarts` count visible),
  sessions on that worker lost with process (sessions in process memory, session externalization to Redis not done);
- **HTTP scenarios no longer need nginx**; HTTPS directly add `--ssl` to lwhyper
  (pure FPC built-in, workers still plaintext; self-signed cert zero config). Front reverse proxy also supported,
  but reverse proxy config no longer needs `ip_hash` / worker list (stickiness managed by lwhyper);
- Regression: `tests/t_hyper.py` (20 items, requires manually starting lwhyper) +
  `tests/t_hyper_ws.py` (6 items WS tunnel, run_with_server fully automatic).

Distribution mechanism (why application-layer stickiness is required, how sid table is maintained, probe/warmup gate/retry semantics,
why WebSocket TCP-level passthrough, single point of failure boundaries) see **`docs/LOADBALANCE.md`**.

## Roadmap

- ~~Print and export~~ ✅ Implemented: `lwreport` report engine (HTML print preview / CSV / XLSX,
  see `demos/dbaware` report center). FastReport commercial library not available locally, LazReport
  strongly bound to LCL preview window/printer (unusable under nogui), so browser print engine is used.
- ~~WebSocket replacing long polling~~ ✅ Implemented (`lwwebsocket`, `tests/t_ws.py`)
- ~~Server-side PDF direct output~~ Temporarily replaced by browser "Save as PDF" (fcl-pdf verified to embed Chinese
  TrueType subset, but that version's ToUnicode/page output is not yet stable)
- ~~Cross-tab session sharing~~ ✅ Implemented (localStorage reuse sid + `/lw/api/attach` +
  cursor push queue, see above)
- ~~Cluster/load balancing~~ ✅ Dual solutions landed: **lwhyper dedicated load balancer** (see "Dedicated Load Balancer" section,
  benchmarked against uniGUI Hyper Server) and nginx/Caddy sticky sessions (`deploy/nginx.conf`'s
  `ip_hash`, `/lw/healthz` probe, `--trust-proxy`; session externalization to Redis not implemented)
- ~~`lwconvert` deepening~~ ✅ Completed (v2: base class rewrite, startup code rewrite, `.lpi` regeneration, support report, `tests/t_convert.py` end-to-end regression)
- ~~Add renderers for high-frequency controls in placeholder~~ ✅ Implemented: `TRadioGroup`/`TCheckGroup`/`TCheckListBox`/`TValueListEditor` (pitfalls 25/42/97), `TDateEdit`/`TTimeEdit` (pitfalls 55/70) all ok, see `docs/CONTROL_MATRIX.md`
- Alpine.js lightweight client ✅ Implemented: **default rendering layer** `lw-alpine.js`, no ext directory needed; Ext JS is optional layer, requires explicit `--client=ext` (pitfalls 89–97)

## Open Source License

This project is open sourced under the [MIT License](LICENSE):

```
MIT License

Copyright (c) 2026 szlbz(QiuFeng) QQ:315795176
```

Free to use, modify, distribute (including commercial use), only need to retain the above copyright notice.

### Ext JS (Optional Dependency) and Licensing Statement

- This project **does not bundle, package, or distribute** any Sencha / Ext JS files (`ext-all.js`,
  theme CSS, charts packages, etc. are all excluded). If you need the Ext rendering layer, obtain `ext-<version>` from Sencha official
  channels and place it in the deployment directory; licensing compliance is borne by the deployer using Ext JS;
- Ext JS is released by Sencha under GPLv3 / commercial dual license, official GPL version only up to 7.0.x,
  later versions go through commercial licensing channels — when using GPLv3 version please comply with its open source terms
  (open application source code, etc.), for commercial closed-source distribution please purchase commercial license;
- Ext rendering layer scripts `lw.js` / `lw.css` are original code of this project, distributed with this project under MIT,
  do not contain, do not derive from any Sencha code;
- Framework default rendering layer is Alpine.js (MIT), **fully functional when no ext directory is placed in deployment**
  (startup auto-detection prefers alpine, `?client=` can switch per request);
- Other third-party dependencies: Lazarus/FPC is modified GPL (runtime linking exception),
  please explain to downstream along with distribution target.

### Alpine.js (Built-in Dependency) and Licensing Statement

- `src/client/alpine.min.js` (3.14.9 official CDN build, no modifications) **distributed with this project**,
  is the only built-in third-party runtime file in the release package;
- Alpine.js is released under MIT (Copyright (c) Caleb Porzio and Alpine.js
  contributors). To satisfy MIT's "retain copyright and license notice" requirement, the distributed file header
  has attached license notice (including official LICENSE link), do not remove when redistributing;
- Project's own `lw-alpine.js` / `lw-alpine.css` are original code, distributed under MIT
  (file header contains SPDX notice);
- Alpine rendering layer is the framework's default rendering layer, deployment requires no external download.

<img width="1836" height="1271" alt="QQ_2026-11-12_17-10-34" src="https://github.com/user-attachments/assets/5b863786-318e-496f-85d9-c603eb295d5a" />
<img width="1845" height="1269" alt="QQ_2026-11-12_17-11-14" src="https://github.com/user-attachments/assets/2f6bb2ff-cae0-4177-b82e-1032c1663d2c" />
<img width="1821" height="1179" alt="QQ_2026-11-12_17-11-33" src="https://github.com/user-attachments/assets/6cf0fb0d-6586-470a-94ca-04641d33620e" />
<img width="1815" height="1170" alt="QQ_2026-11-12_17-11-48" src="https://github.com/user-attachments/assets/305a37e0-0fae-4fb5-b123-fa741f96c0b5" />
<img width="1815" height="1179" alt="QQ_2026-11-12_17-12-04" src="https://github.com/user-attachments/assets/c3ccde1f-ddb7-4089-8073-978f3d0dacaa" />
<img width="1815" height="1184" alt="QQ_2026-11-12_17-12-21" src="https://github.com/user-attachments/assets/5748a74a-e25f-4aed-b3d5-fc23327430b8" />
<img width="1815" height="1173" alt="QQ_2026-11-12_17-12-38" src="https://github.com/user-attachments/assets/54d084f1-e637-4b60-a2ed-7b5f97cccd4f" />
<img width="1809" height="1177" alt="QQ_2026-11-12_17-13-01" src="https://github.com/user-attachments/assets/7fbe0270-3a95-424a-8c35-24fc87f50a05" />
<img width="1815" height="1179" alt="QQ_2026-11-12_17-17-44" src="https://github.com/user-attachments/assets/92e18df9-9ca7-4565-9b78-1e73260f254c" />
<img width="1817" height="1179" alt="QQ_2026-11-12_17-18-11" src="https://github.com/user-attachments/assets/8b8df772-352e-43ad-97e9-f559cfc02b66" />
<img width="1824" height="1173" alt="QQ_2026-11-13_09-15-53" src="https://github.com/user-attachments/assets/90ca9690-cba7-48da-bb30-1cefebaad4d1" />
<img width="1770" height="1118" alt="QQ_2026-11-14_05-46-50" src="https://github.com/user-attachments/assets/c9a81e47-b5a5-45a1-93a2-fd6443108711" />
<img width="895" height="995" alt="ea06f9d6c6f516fa2af43e02e73d267a" src="https://github.com/user-attachments/assets/12276ce3-5c55-403a-b342-b9f2a4831cb3" />
<img width="1280" height="2769" alt="b2340579cb8b66a2d08744b6e7cefff9_720" src="https://github.com/user-attachments/assets/1892599a-91e8-4b40-9a4f-b6214b52cf4a" />
<img width="1083" height="747" alt="c324b8f680f555105b954aeeaf104029" src="https://github.com/user-attachments/assets/008d8db0-8bbd-42a0-b576-6184f0c57960" />
<img width="1284" height="2778" alt="1165bfa448560c9dc2f3cb7e7429f91a" src="https://github.com/user-attachments/assets/52012cd3-bf35-4eb2-b352-cbc791dbb383" />