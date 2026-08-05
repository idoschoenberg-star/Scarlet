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

# 5) Mac-Catalyst @EnvironmentObject drop — the class of crash that hit builds
#    147/148/149: Catalyst does NOT propagate an injected @EnvironmentObject
#    across a NavigationLink→destination OR a .sheet boundary. A detail view that
#    reads `@EnvironmentObject var convo: Conversation` therefore traps
#    (EnvironmentObject.error → SIGTRAP) on open unless it is RE-injected with
#    .environmentObject(convo) at the construction site. This guard fails the
#    build if any convo-reading view is constructed without a nearby re-inject.
py=$(command -v python3 || command -v python)
if [ -n "$py" ]; then
  missing=$("$py" - "$SRC" <<'PY'
import sys, glob, os, re
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "*.swift")))

# (1) Which struct types read `@EnvironmentObject ... convo: Conversation`?
readers = set()
for f in files:
    cur = None
    for line in open(f, encoding="utf-8", errors="ignore"):
        m = re.match(r"\s*struct\s+([A-Za-z_]\w*)", line)
        if m:
            cur = m.group(1)
        if cur and re.search(r"@EnvironmentObject\b.*\bconvo\s*:\s*Conversation", line):
            readers.add(cur)

# (2) Every construction site of a reader type must re-inject convo. Scan the
#     WHOLE expression — the constructor's parenthesized args (which can be a
#     long multi-line literal) plus the trailing `.`-modifier chain — not a
#     fixed line window, so long seeds don't cause false positives.
def code_of(s):
    return s.split("//", 1)[0]

problems = []
for f in files:
    lines = open(f, encoding="utf-8", errors="ignore").read().splitlines()
    for i, line in enumerate(lines):
        for name in readers:
            if re.search(r"\bstruct\s+" + re.escape(name) + r"\b", code_of(line)):
                continue
            m = re.search(r"\b" + re.escape(name) + r"\s*\(", code_of(line))
            if not m:
                continue
            # Walk from the opening paren: accumulate until paren depth returns
            # to 0 (end of args), then keep consuming blank lines and lines whose
            # stripped code starts with '.' (the modifier chain).
            block = []
            depth = 0
            started = False
            j = i
            col = m.end() - 1  # index of '('
            while j < len(lines):
                seg = code_of(lines[j])
                # Include the opening '(' on the first line so it's COUNTED —
                # otherwise a multi-line constructor whose first line has no
                # other paren reads depth 0, the walker thinks the args already
                # closed, and it misses a `.environmentObject` on a later line
                # (a false FATAL). Start at col, not col+1.
                scan = seg[col:] if j == i else seg
                for ch in scan:
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                block.append(lines[j])
                if not started:
                    started = True
                # args closed?
                if started and depth <= 0 and j >= i:
                    # consume trailing modifier chain
                    k = j + 1
                    while k < len(lines):
                        st = code_of(lines[k]).strip()
                        if st == "" or st.startswith(".") or st.startswith(")") or st.startswith("]"):
                            block.append(lines[k]); k += 1
                        else:
                            break
                    break
                j += 1
            if ".environmentObject(" not in "\n".join(block):
                problems.append(f"{os.path.basename(f)}:{i+1}  {name}(...) never re-injects .environmentObject(convo)")
print("\n".join(problems))
PY
)
  if [ -n "$missing" ]; then
    fatal "Conversation @EnvironmentObject not re-injected at a presented/pushed view — Mac Catalyst will SIGTRAP on open:"
    echo "$missing" | sed 's/^/         /'
  else
    ok "every Conversation-reading view re-injects convo at its call sites (Catalyst-safe)"
  fi
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
