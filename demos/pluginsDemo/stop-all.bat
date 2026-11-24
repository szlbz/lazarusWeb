@echo off
rem Kill pluginsDemo host + plugin processes left behind by a hard kill.
rem Filtered by path so the procdemo plugins (same exe names) are untouched.
powershell -NoProfile -Command "Get-Process pluginsdemo,dashplug,notesplug,reportsplug -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\pluginsDemo\*' } | Stop-Process -Force"
echo pluginsDemo processes stopped.
