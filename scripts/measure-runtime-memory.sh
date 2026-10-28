#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 <pid> <label> [csv-output]" >&2
    exit 2
fi

pid="$1"
label="$2"
output_path="${3:-}"

case "$pid" in
    ''|*[!0-9]*) echo "PID must be numeric" >&2; exit 2 ;;
esac

if ! kill -0 "$pid" 2>/dev/null; then
    echo "Process $pid is not running" >&2
    exit 1
fi

footprint_output="$(footprint --pid "$pid" --noCategories -f bytes 2>/dev/null)"
physical_bytes="$(printf '%s\n' "$footprint_output" | awk '/phys_footprint:/ {print $2; exit}')"
peak_bytes="$(printf '%s\n' "$footprint_output" | awk '/phys_footprint_peak:/ {print $2; exit}')"
rss_kib="$(ps -o rss= -p "$pid" | tr -d ' ')"
cpu_percent="$(ps -o %cpu= -p "$pid" | tr -d ' ')"
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

row="$timestamp,$label,$pid,$physical_bytes,$peak_bytes,$rss_kib,$cpu_percent"
if [ -n "$output_path" ]; then
    if [ ! -e "$output_path" ]; then
        printf '%s\n' 'timestamp,label,pid,physical_bytes,peak_bytes,rss_kib,cpu_percent' >"$output_path"
    fi
    printf '%s\n' "$row" >>"$output_path"
fi

printf '%s\n' 'timestamp,label,pid,physical_bytes,peak_bytes,rss_kib,cpu_percent'
printf '%s\n' "$row"
