@echo off
setlocal
rem Trust the lazarusWeb local CA for the current Windows user.
rem Fixes: the installed PWA window shows NET::ERR_CERT_AUTHORITY_INVALID,
rem and clicking "Advanced - Continue to 127.0.0.1" opens a normal browser
rem tab instead of staying in the standalone app window.
rem Usage: trust-ca.bat [path\to\ca.crt]

set "CA=%~1"
if "%CA%"=="" set "CA=%~dp0..\..\cert-ca\ca.crt"
if not exist "%CA%" (
  echo ERROR: CA certificate not found: %CA%
  exit /b 1
)

echo Installing CA into CurrentUser\Root:
echo   %CA%
echo.
echo A Windows security warning will appear. Click Yes to trust it.
echo.
certutil -user -addstore Root "%CA%"
if errorlevel 1 (
  echo.
  echo FAILED.
  echo Import manually: double-click ca.crt - Install Certificate -
  echo Current User - Place all certificates in:
  echo   Trusted Root Certification Authorities.
  exit /b 1
)

echo.
echo OK. Now:
echo   1) Fully exit Edge/Chrome - all windows, including tray/background.
echo   2) Delete the old desktop icon.
echo   3) Open https://127.0.0.1:8878/ and install the PWA again.
exit /b 0
