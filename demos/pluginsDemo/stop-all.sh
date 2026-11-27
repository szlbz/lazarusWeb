#!/usr/bin/env bash
# Stop pluginsDemo host + plugin processes left behind by a hard kill.
# Filter by executable path under this demo directory so other demos with
# the same exe names (e.g. procdemo) are untouched.
set -u

# 本脚本用了 bash 专有语法（${BASH_SOURCE[0]}、${x##*/}），
# Ubuntu 的 /bin/sh 是 dash，直接 `sh stop-all.sh` 会报
# "Bad substitution" 并把 HERE 留空。不是 bash 就以 bash 重新执行自己。
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMES=" pluginsdemo dashplug notesplug reportsplug "
KILLED=0

for d in /proc/[0-9]*; do
  [ -r "$d/exe" ] || continue
  pid="${d#/proc/}"
  [ "$pid" = "$$" ] && continue
  exe="$(readlink "$d/exe" 2>/dev/null)" || continue
  case "$exe" in
    "$HERE"/*) ;;
    *) continue ;;
  esac
  base="${exe##*/}"
  base="${base% (deleted)}"
  case "$NAMES" in
    *" $base "*) ;;
    *) continue ;;
  esac
  if kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; then
    KILLED=$((KILLED + 1))
  fi
done

echo "pluginsDemo processes stopped ($KILLED)."
