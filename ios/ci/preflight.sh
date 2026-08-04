#!/usr/bin/env bash
# Pre-flight QA gate — runs in ios.yml BEFORE the archive so a broken build
# never reaches TestFlight (and Ido never becomes the crash-finder).
#
# The Swift compiler already catches syntax/type errors during the build. This
# gate catches the class of problems the compiler does NOT: documented App
# Store silent-rejections and known Mac-Catalyst runtime crashers that only bite
# at runtime on a real device. FATAL checks exit non-zero and stop the upload;
# WARN checks are advisory.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2   # -> ios/
SRC="Sources"
fail=0
warn=0
fatal() { echo "❌ FATAL: $*"; fail=1; }
warning() { echo "⚠️  WARN:  $*"; warn=1; }
ok() { echo "✅ $*"; }

echo "── Scarlet pre-flight QA gate ──"

# 1) The crash black-box MUST be installed — we never ship blind again.
if grep -q "FlightRecorder.installCrashHandlers()" "$SRC/ScarletTalkApp.swift"; then
  ok "crash reporter is installed at launch"
else
  fatal "FlightRecorder.installCrashHandlers() is not called at launch — the crash black-box is missing."
fi

# 2) ITMS-90626: a non-empty INAlternativeAppNames / Siri synonym gets the build
#    SILENTLY rejected AFTER a successful upload (it never appears in TestFlight).
if grep -rn "INAlternativeAppNames" "$SRC" project.yml 2>/dev/null \
     | grep -vE "(#|//|<!--|NOTE|REMOVED)" | grep -q .; then
  fatal "INAlternativeAppNames is present — ITMS-90626 will silently reject the build. Remove it."
else
  ok "no INAlternativeAppNames (ITMS-90626 safe)"
fi

# 3) Conversation.shared must stay a TRUE singleton — a second instance
#    double-installs the audio tap and crashes.
convo_inits=$(grep -rn "Conversation(" "$SRC" | grep -vE "//|static let shared = Conversation\(\)" | grep -c "Conversation(")
if [ "$convo_inits" -gt 0 ]; then
  fatal "Conversation() is instantiated outside its shared singleton ($convo_inits site(s)) — double audio-tap crash."
else
  ok "Conversation is a single shared instance"
fi

# 4) Advisory: bracket balance per file (a real error still fails the compile;
#    this just surfaces a likely bad merge earlier, and ignores false positives).
py=$(command -v python3 || command -v python)
if [ -n "$py" ]; then
  imbalanced=$("$py" - "$SRC" <<'PY'
import sys, glob, os
root = sys.argv[1]
bad = []
for f in glob.glob(os.path.join(root, "*.swift")):
    s = open(f, encoding="utf-8", errors="ignore").read()
    for o, c in (("{", "}"), ("(", ")"), ("[", "]")):
        if s.count(o) != s.count(c):
            bad.append(f"{os.path.basename(f)} {o}{c} {s.count(o)}/{s.count(c)}")
print("\n".join(bad))
PY
)
  if [ -n "$imbalanced" ]; then
    warning "bracket counts look off (may be string/regex literals — the compile is authoritative):"
    echo "$imbalanced" | sed 's/^/         /'
  else
    ok "bracket balance looks sane across all Swift files"
  fi
fi

echo "────────────────────────────────"
if [ "$fail" -ne 0 ]; then
  echo "Pre-flight FAILED — not shipping this build."
  exit 1
fi
[ "$warn" -ne 0 ] && echo "Pre-flight passed with warnings."
echo "Pre-flight passed."
exit 0
