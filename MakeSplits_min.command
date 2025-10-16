#!/bin/bash
# MakeSplits_min.command — double-click: choose master audio -> Desktop/splits.csv
# Safe version: no 'set -u', ASCII-only, robust mktemp and error pauses.

set -e -o pipefail
trap 'status=$?; echo ""; echo "Script exited with code $status. Press any key to close..."; read -n 1 -s -r; exit $status' ERR

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1. Install with: brew install ffmpeg python"; exit 1; }; }
need ffmpeg
need ffprobe
need python3
need osascript

choose_file() {
  osascript <<'OSA' 2>/dev/null
set f to choose file with prompt "Choose master audio (mp3/m4a/wav etc.)"
POSIX path of f
OSA
}

INPUT="$(choose_file || true)"
if [ -z "$INPUT" ]; then
  echo "Drag your master audio file here, then press Enter:"
  read -r INPUT || true
fi

INPUT="${INPUT%\"}"; INPUT="${INPUT#\"}"; INPUT="$(printf "%s" "$INPUT" | sed 's/[[:space:]]*$//')"

if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
  echo "Invalid file: $INPUT"
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi

echo "Selected: $INPUT"

NOISE="-32dB"
DUR_SIL="0.30"
MIN_GAP="0.60"
MIN_SEG="1.20"
LEAD="0.00"
TAIL="0.00"

LOG="$(mktemp -t silence_log).log"

echo "Detecting silence (noise=$NOISE, d=$DUR_SIL)..."
ffmpeg -hide_banner -nostats -i "$INPUT" -af "silencedetect=noise=${NOISE}:d=${DUR_SIL}" -f null - 2> "$LOG"

echo "Building splits.csv ..."
python3 - "$INPUT" "$LOG" "$MIN_GAP" "$MIN_SEG" "$LEAD" "$TAIL" << 'PY'
import re, sys, subprocess
from pathlib import Path

inp, log_path, MIN_GAP, MIN_SEG, LEAD, TAIL = sys.argv[1], sys.argv[2], *sys.argv[3:7]
MIN_GAP  = float(MIN_GAP); MIN_SEG = float(MIN_SEG); LEAD=float(LEAD); TAIL=float(TAIL)

def duration_sec(path):
    out = subprocess.check_output(
        ['ffprobe','-v','error','-show_entries','format=duration','-of','default=nw=1:nk=1', path]
    ).decode().strip()
    return float(out)

def fmt(t):
    if t < 0: t = 0.0
    h = int(t // 3600); m = int((t % 3600)//60); s = t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"

dur = duration_sec(inp)
txt = Path(log_path).read_text(encoding='utf-8', errors='ignore')

starts = [float(x) for x in re.findall(r"silence_start:\s*([\d.]+)", txt)]
ends   = [float(x) for x in re.findall(r"silence_end:\s*([\d.]+)", txt)]

cuts = sorted((s+e)/2 for s, e in zip(starts, ends))

merged = []
for t in cuts:
    if not merged or t - merged[-1] >= MIN_GAP:
        merged.append(t)
cuts = merged

segments = []
prev = 0.0
for t in cuts + [dur]:
    a, b = prev, t
    prev = t
    if b <= a: 
        continue
    if segments and (b - a) < MIN_SEG:
        segments[-1] = (segments[-1][0], b)
    else:
        segments.append((a, b))

home = Path.home()
out  = home / "Desktop" / "splits.csv"
stem = Path(inp).stem

def clamp(x): return max(0.0, min(dur, x))
def fmt2(x):
    h=int(x//3600); m=int((x%3600)//60); s=x%60
    return f"{h:02d}:{m:02d}:{s:06.3f}"

with out.open('w', encoding='utf-8') as f:
    for i, (a, b) in enumerate(segments, 1):
        a2 = clamp(a + float(LEAD))
        b2 = clamp(b - float(TAIL))
        if b2 - a2 <= 0.05: 
            continue
        f.write(f"{fmt2(a2)},{fmt2(b2)},{stem}_{i:02d}\n")

print(f"OK -> {out}")
PY

echo "Done. splits.csv is on your Desktop."
read -n 1 -s -r -p "Press any key to close..."
