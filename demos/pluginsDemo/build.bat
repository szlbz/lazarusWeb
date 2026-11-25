@echo off
rem pluginsDemo: build the 3 plugin exes first, then the host.
rem Order matters: host and plugins both link common\upluginguard.pas, so a
rem changed guard/secret must be compiled into BOTH sides or the token check
rem fails and no plugin starts.
rem keep this file ASCII + CRLF, cmd.exe chokes on UTF-8 comments
rem lazbuild is searched on PATH first, then common install locations
rem set LAZBUILD env var to override all of them
setlocal
if defined LAZBUILD goto havetool
set LAZBUILD=lazbuild.exe
if exist "%ProgramFiles%\Lazarus\lazbuild.exe" set LAZBUILD=%ProgramFiles%\Lazarus\lazbuild.exe
if exist "%LocalAppData%\Lazarus\lazbuild.exe" set LAZBUILD=%LocalAppData%\Lazarus\lazbuild.exe
if exist "%SystemDrive%\lazarus\lazbuild.exe" set LAZBUILD=%SystemDrive%\lazarus\lazbuild.exe
if exist "C://lazarus//lazbuild.exe" set LAZBUILD=C://lazarus//lazbuild.exe
if exist "C://111//lazarus//lazbuild.exe" set LAZBUILD=C://111//lazarus//lazbuild.exe
:havetool
set HERE=%~dp0
for %%P in (dashplug notesplug reportsplug) do (
  echo === %%P ===
  "%LAZBUILD%" -B "%HERE%%%P\%%P.lpi"
  if errorlevel 1 goto fail
)
echo === host ===
"%LAZBUILD%" -B "%HERE%host\pluginsdemo.lpi"
if errorlevel 1 goto fail
echo.
echo  run:  host\pluginsdemo.exe
echo  open: https://127.0.0.1:8878/
echo  hint: plugin exe refuses to run on its own (start guard)
goto end
:fail
echo.
echo BUILD FAILED - see the lazbuild output above.
:end
endlocal
