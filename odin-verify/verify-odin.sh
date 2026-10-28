#!/usr/bin/env bash
# Verify upstream colbymchenry/codegraph PR #1523 (Odin support) rebased onto
# current main, on THIS machine (built for macOS; works on Linux too).
#
#   ./verify-odin.sh [--full] [/path/to/odin/project ...]
#
#   --full   also run the whole vitest suite (slower; the default only runs
#            the extraction + resolution suites, which contain the Odin tests)
#   paths    your own Odin projects to index (read-only: a .codegraph/ dir is
#            created INSIDE a throwaway copy, never in your original folder)
#
# Needs: git, node (>=22.5 recommended, <25), npm, sqlite3 (preinstalled on
# macOS). Everything happens under $WORKDIR; nothing is installed globally and
# nothing is pushed anywhere. Output is also saved to $WORKDIR/report.txt —
# paste that file back.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/odin-1523-on-main.patch"
BASE_SHA="69af19ace270f2e940444d514de6dde971df12df"   # upstream main the patch was made against
WORKDIR="${WORKDIR:-$HOME/codegraph-odin-verify}"
FULL=0
PROJECTS=()
for a in "$@"; do
  case "$a" in
    --full) FULL=1 ;;
    *) PROJECTS+=("$a") ;;
  esac
done

export CODEGRAPH_TELEMETRY=0          # no usage stats from these runs
mkdir -p "$WORKDIR"
REPORT="$WORKDIR/report.txt"
: > "$REPORT"
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
die() { say "FATAL: $*"; exit 1; }

for tool in git node npm sqlite3; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
[ -f "$PATCH" ] || die "patch not found next to this script: $PATCH"

say "== environment"
say "uname:  $(uname -srm)"
say "node:   $(node --version)   npm: $(npm --version)"
say "date:   $(date -u +%FT%TZ)"

# ---------------------------------------------------------------- checkout
SRC="$WORKDIR/codegraph"
if [ ! -d "$SRC/.git" ]; then
  say "== cloning upstream (shallow) ..."
  git clone -q --filter=blob:none --no-checkout https://github.com/colbymchenry/codegraph "$SRC" || die "clone failed"
fi
cd "$SRC" || die "cd failed"
git fetch -q origin "$BASE_SHA" 2>/dev/null || git fetch -q origin main || die "fetch failed"
git checkout -q -f "$BASE_SHA" || die "cannot check out base $BASE_SHA"
git clean -fdq -e node_modules
git apply --binary "$PATCH" || die "patch does not apply cleanly"
say "== patched tree: upstream $BASE_SHA + PR #1523 (conflicts resolved)"
git status --short | sed 's/^/   /' | tee -a "$REPORT"

# ------------------------------------------------------------- build + test
say "== npm ci"
npm ci --ignore-scripts >"$WORKDIR/npm-ci.log" 2>&1 || { tail -20 "$WORKDIR/npm-ci.log"; die "npm ci failed (log: $WORKDIR/npm-ci.log)"; }
say "== build"
npm run build >"$WORKDIR/build.log" 2>&1 && say "build: OK" || { tail -20 "$WORKDIR/build.log"; die "build failed (log: $WORKDIR/build.log)"; }

say "== tests"
if [ "$FULL" = 1 ]; then
  npx vitest run >"$WORKDIR/tests.log" 2>&1
else
  npx vitest run __tests__/extraction.test.ts __tests__/resolution.test.ts >"$WORKDIR/tests.log" 2>&1
fi
say "vitest exit: $?   (log: $WORKDIR/tests.log)"
grep -E "Test Files|Tests |FAIL" "$WORKDIR/tests.log" | sed 's/^/   /' | tee -a "$REPORT"
say "(known: glyphs.test.ts 'returns Unicode glyphs on macOS' fails on Linux containers even on unmodified main — on a real Mac it should pass)"

CG=(node "$SRC/dist/bin/codegraph.js")

# ----------------------------------------------------------------- indexing
sql() { sqlite3 -readonly "$1/.codegraph/codegraph.db" "$2" 2>/dev/null; }

report_project() {
  local label="$1" dir="$2"
  say ""
  say "######## $label"
  say "path: $dir"
  local disk; disk=$(find "$dir" -name '*.odin' -not -path '*/.codegraph/*' -not -path '*/.git/*' | wc -l | tr -d ' ')
  say ".odin files on disk: $disk"
  ( cd "$dir" && rm -rf .codegraph && "${CG[@]}" init -i >"$WORKDIR/index-$label.log" 2>&1 ); local rc=$?
  say "index exit: $rc"
  grep -E "Indexed|nodes," "$WORKDIR/index-$label.log" | sed 's/^/   /' | tee -a "$REPORT"
  [ -f "$dir/.codegraph/codegraph.db" ] || { say "NO DATABASE PRODUCED"; return; }
  say "-- odin file nodes:        $(sql "$dir" "select count(*) from nodes where kind='file' and language='odin'")"
  say "-- odin files w/ symbols:  $(sql "$dir" "select count(distinct file_path) from nodes where language='odin' and kind!='file'")"
  say "-- odin nodes by kind:"
  sql "$dir" "select kind||'='||count(*) from nodes where language='odin' group by kind order by count(*) desc" | paste -sd' ' - | sed 's/^/   /' | tee -a "$REPORT"
  say "-- edges by kind:"
  sql "$dir" "select kind||'='||count(*) from edges group by kind order by count(*) desc" | paste -sd' ' - | sed 's/^/   /' | tee -a "$REPORT"
  say "-- files with parse errors recorded:"
  sql "$dir" "select path from files where errors is not null and language='odin' limit 15" | sed 's/^/   /' | tee -a "$REPORT"
  say "-- odin files with ZERO symbols (empty is fine for tiny/constant-less files):"
  sql "$dir" "select f.file_path from nodes f where f.kind='file' and f.language='odin' and not exists (select 1 from nodes n where n.file_path=f.file_path and n.kind!='file') limit 15" | sed 's/^/   /' | tee -a "$REPORT"
  say "-- top 12 unresolved odin calls (stdlib/vendor names are expected):"
  sql "$dir" "select reference_name||' x'||count(*) from unresolved_refs where reference_kind='calls' and language='odin' group by reference_name order by count(*) desc limit 12" | sed 's/^/   /' | tee -a "$REPORT"
  say "-- resolved vs unresolved calls: $(sql "$dir" "select count(*) from edges where kind='calls'") resolved / $(sql "$dir" "select count(*) from unresolved_refs where reference_kind='calls' and language='odin'") unresolved"
  say "-- 5 most-called odin procedures (sanity: do these look like your real hot spots?):"
  sql "$dir" "select n.name||' ('||n.file_path||') <- '||count(*) from edges e join nodes n on n.id=e.target where e.kind='calls' and n.language='odin' and n.kind='function' group by n.id order by count(*) desc limit 5" | sed 's/^/   /' | tee -a "$REPORT"
}

say ""
say "== PUBLIC REPOS (compare with the Linux run: ols 5778 nodes/12575 edges, odin-http 1646/2972, examples 2120/2658)"
PUB="$WORKDIR/public"; mkdir -p "$PUB"
clone_at() { # name url sha
  [ -d "$PUB/$1/.git" ] || git clone -q "$2" "$PUB/$1"
  git -C "$PUB/$1" fetch -q --depth 1 origin "$3" 2>/dev/null; git -C "$PUB/$1" checkout -q -f "$3" 2>/dev/null || say "(could not pin $1 to $3; using whatever HEAD is)"
}
clone_at ols        https://github.com/DanielGavin/ols     3df28abc33133805c0bf83101d4d35fab395479d
clone_at odin-http  https://github.com/laytan/odin-http    fac113fbd828aad3d71479a534b5de4358b6a07b
clone_at examples   https://github.com/odin-lang/examples  5d24fd4388552d2bd6baf830230dcd045cd7187d
for r in ols odin-http examples; do report_project "$r" "$PUB/$r"; done

if [ ${#PROJECTS[@]} -gt 0 ]; then
  say ""
  say "== YOUR PROJECTS (indexed from throwaway copies; originals untouched)"
  for p in "${PROJECTS[@]}"; do
    [ -d "$p" ] || { say "skip (not a directory): $p"; continue; }
    name="$(basename "$p")"
    copy="$WORKDIR/mine/$name"; rm -rf "$copy"; mkdir -p "$WORKDIR/mine"
    # copy without .git/.codegraph/build junk; keeps .gitignore so ignore rules still apply
    if command -v rsync >/dev/null; then rsync -a --exclude .codegraph --exclude node_modules "$p"/ "$copy"/; else cp -R "$p" "$copy"; rm -rf "$copy/.codegraph"; fi
    report_project "mine-$name" "$copy"
  done
fi

say ""
say "== done. Paste this file back: $REPORT"
