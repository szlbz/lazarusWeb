#!/usr/bin/env bash
# pluginsDemo: build the 3 plugin exes first, then the host.
# Order matters: host and plugins both link common/upluginguard.pas, so a
# changed guard/secret must be compiled into BOTH sides or the token check
# fails and no plugin starts.
# Linux build: FPC emits dashplug / notesplug / reportsplug (no .exe suffix);
# the plugin manifests still say exe=xxx.exe and upluginproc falls back to
# the suffix-less file automatically.
# Override tool: LAZBUILD=/path/to/lazbuild ./build.sh
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"

if ! command -v "$LAZBUILD" >/dev/null 2>&1; then
  echo "lazbuild not found: $LAZBUILD" >&2
  echo "Install Lazarus or set LAZBUILD=/path/to/lazbuild" >&2
  exit 1
fi

for p in dashplug notesplug reportsplug; do
  echo "=== $p ==="
  "$LAZBUILD" -B "$HERE/$p/$p.lpi"
done

echo "=== host ==="
"$LAZBUILD" -B "$HERE/host/pluginsdemo.lpi"

echo
echo "run:  $HERE/host/pluginsdemo"
echo "open: https://127.0.0.1:8878/"
echo "hint: plugin exe refuses to run on its own (start guard)"
