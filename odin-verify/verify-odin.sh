#!/usr/bin/env bash
# Verify CodeGraph's Odin support (colbymchenry/codegraph#3091) on THIS machine.
#
#   ./verify-odin.sh [--full] [--stdlib] [/path/to/your/odin/project ...]
#
#   --full     also run the whole vitest suite (slow; the default runs the
#              extraction + resolution suites, which hold every Odin test)
#   --stdlib   also index Odin's own core/base/tests/examples (~1,900 files,
#              needs ~a minute and a few hundred MB)
#   paths      your own Odin projects. They are copied first; your originals
#              are never written to.
#
# What it does, in order (this is exactly the flow the PR asks a maintainer
# to follow, so a pass here also tests the PR's own build instructions):
#   1. clones the PR branch from RainerXE/codegraph and builds it
#   2. runs the Odin tests WITHOUT the grammar  (expect: only Odin tests fail)
#   3. builds tree-sitter-odin.wasm from the pinned v1.3.0 tag, after checking
#      the grammar source hashes against docs/grammars/tree-sitter-odin.md
#   4. runs the tests WITH the grammar          (expect: all pass)
#   5. indexes pinned public Odin repos and compares node/edge counts with the
#      Linux run (expected-linux.tsv, next to this script)
#   6. indexes your own projects, if you pass any
#
# Needs: git, node, npm, internet access. (If your node is outside >=22.5 <25 the
# script fetches a private Node 22 for the run, leaving your install alone.) Works on macOS and
# Linux. Everything lives under $WORKDIR; nothing is installed globally and
# nothing is pushed anywhere. Results are also saved to $WORKDIR/report.txt:
# paste that file back.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/codegraph-odin-verify}"
FORK="${FORK:-https://github.com/RainerXE/codegraph}"
BRANCH="${BRANCH:-claude/odin-language-support}"
GRAMMAR_REPO="https://github.com/tree-sitter-grammars/tree-sitter-odin"
GRAMMAR_TAG="v1.3.0"
GRAMMAR_COMMIT="e8adc739b78409a99f8c31313f0bb54cc538cf73"
PARSER_C_SHA="8f672d8d022d70eeae822796924f2e45e692d6b2acd2ddc79bfeb5f696fa24f0"
SCANNER_C_SHA="e342d07d3e35c3865a6bda0587f3a3b46a7b2411fd93cbee01dc40ab7631c93b"
TS_CLI="0.26.11"

FULL=0; STDLIB=0; PROJECTS=()
for a in "$@"; do
  case "$a" in
    --full) FULL=1 ;;
    --stdlib) STDLIB=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) PROJECTS+=("$a") ;;
  esac
done

export CODEGRAPH_TELEMETRY=0 GIT_TERMINAL_PROMPT=0
mkdir -p "$WORKDIR"
REPORT="$WORKDIR/report.txt"; : > "$REPORT"
say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
die() { say "FATAL: $*"; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
elapsed() { echo $(( $(date +%s) - $1 )); }

for t in git node npm; do command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"; done
node_ok() { # Node >=22.5 and <25
  local major minor
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  minor="$(node -p 'process.versions.node.split(".")[1]' 2>/dev/null)" || return 1
  { [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 5 ]; }; } && [ "$major" -lt 25 ]
}
if [ -n "${FORCE_NODE_BOOTSTRAP:-}" ] || ! node_ok; then
  # CodeGraph supports Node >=22.5 <25. Rather than touch your install (nvm, brew, ...),
  # fetch a private Node 22 into the work folder and use it for this run only.
  say_early() { printf '%s\n' "$*"; }
  say_early "Your node is $(node --version) — CodeGraph needs >=22.5 <25. Fetching a private Node 22 into $WORKDIR/node22 (your install is untouched) ..."
  mkdir -p "$WORKDIR/node22"
  ( cd "$WORKDIR/node22" && npm init -y >/dev/null 2>&1 && npm install node@22 >"$WORKDIR/node22-install.log" 2>&1 ) \
    || { tail -10 "$WORKDIR/node22-install.log"; echo "FATAL: could not fetch Node 22 (log: $WORKDIR/node22-install.log). Install Node 22 yourself (e.g. 'nvm install 22' or 'brew install node@22') and re-run."; exit 1; }
  export PATH="$WORKDIR/node22/node_modules/node/bin:$PATH"
  hash -r
  node_ok || { echo "FATAL: private Node 22 did not take effect (node is $(node --version))"; exit 1; }
fi

say "== environment"
say "uname:  $(uname -srm)"
say "node:   $(node --version)    npm: $(npm --version)    git: $(git --version | cut -d' ' -f3)"
say "date:   $(date -u +%FT%TZ)"

# --------------------------------------------------------------- 1. checkout
SRC="$WORKDIR/codegraph"
rm -rf "$SRC"
say ""; say "== 1. clone + build  ($FORK @ $BRANCH)"
git clone -q --depth 50 --branch "$BRANCH" "$FORK" "$SRC" || die "clone failed (is $FORK public, and does branch $BRANCH exist?)"
cd "$SRC" || die "cd failed"
say "head:   $(git rev-parse HEAD)"
say "commits on top of upstream main (author | subject):"
git log --format='   %h %an | %s' -3 | tee -a "$REPORT"
git ls-files | grep -q 'tree-sitter-odin\.wasm' && say "NOTE: the branch ships an odin wasm (unexpected)"
T0=$(date +%s)
npm ci --ignore-scripts >"$WORKDIR/npm-ci.log" 2>&1 || { tail -15 "$WORKDIR/npm-ci.log"; die "npm ci failed (log: $WORKDIR/npm-ci.log)"; }
say "npm ci:  ok ($(elapsed $T0)s)"

TESTS="__tests__/extraction.test.ts __tests__/resolution.test.ts"
vt() { npx vitest run "$@" 2>&1; }

# ------------------------------------------- 2. tests without the grammar
say ""; say "== 2. Odin tests WITHOUT the grammar (the state of the PR before a maintainer adds the wasm)"
rm -f src/extraction/wasm/tree-sitter-odin.wasm
OUT="$(vt $TESTS)"
echo "$OUT" > "$WORKDIR/tests-without-wasm.log"
NOWASM_SUMMARY="$(echo "$OUT" | grep -E '^\s+Tests ' | head -1 | sed 's/^ *//')"
NONODIN_FAIL="$(echo "$OUT" | grep '×' | grep -vc 'Odin' || true)"
say "result: $NOWASM_SUMMARY"
say "failures that are NOT Odin tests: $NONODIN_FAIL   (expected 0; expected summary: 25 failed | 1018 passed)"

# -------------------------------------------------- 3. build the grammar
say ""; say "== 3. build tree-sitter-odin.wasm from $GRAMMAR_TAG"
G="$WORKDIR/tree-sitter-odin"
rm -rf "$G"
git clone -q "$GRAMMAR_REPO" "$G" || die "grammar clone failed"
git -C "$G" checkout -q "$GRAMMAR_TAG" || die "no such tag"
GC="$(git -C "$G" rev-parse HEAD)"
[ "$GC" = "$GRAMMAR_COMMIT" ] && say "commit:  $GC  (matches the doc)" || say "MISMATCH commit: $GC (doc says $GRAMMAR_COMMIT)"
P="$(sha256 "$G/src/parser.c")"; S="$(sha256 "$G/src/scanner.c")"
[ "$P" = "$PARSER_C_SHA" ] && say "parser.c:  sha256 matches the doc" || say "MISMATCH parser.c: $P"
[ "$S" = "$SCANNER_C_SHA" ] && say "scanner.c: sha256 matches the doc" || say "MISMATCH scanner.c: $S"
say "licence: $(sed -n 1,3p "$G/LICENSE" | tr '\n' ' ')"
CLI="$WORKDIR/ts-cli"; rm -rf "$CLI"; mkdir -p "$CLI"
( cd "$CLI" && npm init -y >/dev/null 2>&1 && npm install "tree-sitter-cli@$TS_CLI" >"$WORKDIR/ts-cli-install.log" 2>&1 ) || die "could not install tree-sitter-cli@$TS_CLI (log: $WORKDIR/ts-cli-install.log)"
T0=$(date +%s)
( cd "$G" && "$CLI/node_modules/.bin/tree-sitter" build --wasm -o "$G/tree-sitter-odin.wasm" ) >"$WORKDIR/wasm-build.log" 2>&1 \
  || { tail -15 "$WORKDIR/wasm-build.log"; die "wasm build failed (log: $WORKDIR/wasm-build.log)"; }
WSZ="$(wc -c < "$G/tree-sitter-odin.wasm" | tr -d ' ')"
say "built:   tree-sitter-odin.wasm  ${WSZ} bytes, sha256 $(sha256 "$G/tree-sitter-odin.wasm")  ($(elapsed $T0)s)"
say "(reference builds: Windows 2218713 bytes, Linux 2218722 bytes. Bytes differ per toolchain; behaviour does not.)"
cp "$G/tree-sitter-odin.wasm" "$SRC/src/extraction/wasm/tree-sitter-odin.wasm"

# --------------------------------------------------- 4. tests with the grammar
say ""; say "== 4. tests WITH the grammar"
if [ "$FULL" = 1 ]; then OUT="$(vt)"; else OUT="$(vt $TESTS)"; fi
echo "$OUT" > "$WORKDIR/tests-with-wasm.log"
say "result: $(echo "$OUT" | grep -E '^\s+Tests ' | head -1 | sed 's/^ *//')"
if [ "$FULL" = 1 ]; then
  say "expected (Linux): 5 failed | 9246 passed | 434 skipped; the 5 failures are the glyph test (passes on a real Mac) and four gitignore-pattern-parity tests, all failing the same way on unmodified upstream main"
else
  say "expected (Linux): 1043 passed, 0 failed"
fi
echo "$OUT" | grep '×' | sed 's/^/   FAIL: /' | head -20 | tee -a "$REPORT"

say ""; say "== build"
npm run build >"$WORKDIR/build.log" 2>&1 && say "npm run build: ok" || { tail -15 "$WORKDIR/build.log"; die "build failed"; }
CG="node $SRC/dist/bin/codegraph.js"

# ------------------------------------------------------------- 5. corpora
RES="$WORKDIR/results.tsv"; : > "$RES"
index_one() { # label dir
  local label="$1" dir="$2" disk idx nodes edges
  disk=$(find "$dir" -name '*.odin' -not -path '*/.git/*' -not -path '*/.codegraph/*' | wc -l | tr -d ' ')
  rm -rf "$dir/.codegraph"
  local T1=$(date +%s)
  ( cd "$dir" && $CG init -i >"$WORKDIR/index-$label.log" 2>&1 ); local rc=$?
  local db="$dir/.codegraph/codegraph.db"
  if [ ! -f "$db" ]; then say "$label: NO DATABASE (exit $rc, log $WORKDIR/index-$label.log)"; return; fi
  local row
  row="$(node -e "
    const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('$db',{readOnly:true});
    const n=(s)=>d.prepare(s).get().c;
    const out=[n(\"select count(*) c from nodes where kind='file' and language='odin'\"),
               n('select count(*) c from nodes'),n('select count(*) c from edges'),
               n(\"select count(*) c from edges where kind='calls'\"),
               n(\"select count(distinct file_path) c from nodes where language='odin' and kind!='file'\"),
               n(\"select count(*) c from files where errors is not null and language='odin'\")];
    console.log(out.join('\t'))" 2>/dev/null)"
  local idx nodes edges calls syms ferr
  idx=$(echo "$row" | cut -f1); nodes=$(echo "$row" | cut -f2); edges=$(echo "$row" | cut -f3)
  calls=$(echo "$row" | cut -f4); syms=$(echo "$row" | cut -f5); ferr=$(echo "$row" | cut -f6)
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$disk" "$idx" "$nodes" "$edges" >> "$RES"
  printf '   %-26s odin files %5s  indexed %5s  w/symbols %5s  nodes %7s  edges %7s  calls %6s  file-errors %s  (%ss)\n' \
    "$label" "$disk" "$idx" "$syms" "$nodes" "$edges" "$calls" "$ferr" "$(elapsed $T1)" | tee -a "$REPORT"
}
clone_pin() { # name url sha
  local d="$WORKDIR/public/$1"
  [ -d "$d/.git" ] || { mkdir -p "$d" && git -C "$d" init -q && git -C "$d" remote add origin "$2"; }
  git -C "$d" fetch -q --depth 1 origin "$3" 2>/dev/null && git -C "$d" checkout -q -f FETCH_HEAD 2>/dev/null \
    || { say "   (could not pin $1 at $3 — skipping)"; return 1; }
}

say ""; say "== 5. pinned public repos"
mkdir -p "$WORKDIR/public"
while read -r name url sha; do
  [ -z "$name" ] && continue
  clone_pin "$name" "$url" "$sha" && index_one "$name" "$WORKDIR/public/$name"
done <<'REPOS'
ols             https://github.com/DanielGavin/ols               3df28abc33133805c0bf83101d4d35fab395479d
odin-http       https://github.com/laytan/odin-http              fac113fbd828aad3d71479a534b5de4358b6a07b
examples        https://github.com/odin-lang/examples            5d24fd4388552d2bd6baf830230dcd045cd7187d
karl2d          https://github.com/karl-zylinski/karl2d          4e7d845ed940f90d70eded1ad040a7bae93a2033
ravn            https://github.com/jakubtomsu/ravn               ae5c0b732271797809f3d408dd44c6d7065e6690
sokol-odin      https://github.com/floooh/sokol-odin            cdef8e58162cd657c453e65cb087b9cb5888adb9
todool          https://github.com/Skytrias/todool               dccef1c3a08aa3d0c9f6dafc7e9170cf0808a761
lucynes         https://github.com/lucypero/lucynes              7600f161303c41e44a772775fe2d1f767584b37c
spall-web       https://github.com/colrdavidson/spall-web        9403174cbefb01f49370bc352d67adb0c4eea948
REPOS

if [ "$STDLIB" = 1 ]; then
  d="$WORKDIR/public/Odin"
  if [ ! -d "$d/.git" ]; then
    git clone -q --depth 1 --branch dev-2026-10 --filter=blob:none --sparse https://github.com/odin-lang/Odin "$d" \
      && git -C "$d" sparse-checkout set core base vendor tests examples
  fi
  [ -d "$d/core" ] && index_one "Odin-dev-2026-10" "$d"
fi

say ""; say "== comparison with the Linux run (odin files / indexed / nodes / edges must be identical)"
EXP="$HERE/expected-linux.tsv"
if [ -f "$EXP" ]; then
  while IFS="$(printf '\t')" read -r label disk idx nodes edges; do
    want="$(awk -F'\t' -v l="$label" '$1==l' "$EXP")"
    if [ -z "$want" ]; then say "   $label: no Linux reference"; continue; fi
    if [ "$want" = "$(printf '%s\t%s\t%s\t%s\t%s' "$label" "$disk" "$idx" "$nodes" "$edges")" ]; then
      say "   MATCH  $label"
    else
      say "   DIFF   $label"; say "          linux: $(echo "$want" | cut -f2-)"; say "          here:  $disk	$idx	$nodes	$edges"
    fi
  done < "$RES"
else
  say "   (no expected-linux.tsv found next to the script)"
fi

# ----------------------------------------------------------- 6. your projects
if [ ${#PROJECTS[@]} -gt 0 ]; then
  say ""; say "== 6. your projects (indexed from copies; originals untouched)"
  mkdir -p "$WORKDIR/mine"
  for p in "${PROJECTS[@]}"; do
    [ -d "$p" ] || { say "   skip (not a directory): $p"; continue; }
    name="$(basename "$p")"; copy="$WORKDIR/mine/$name"
    rm -rf "$copy"
    if command -v rsync >/dev/null 2>&1; then rsync -a --exclude .codegraph --exclude node_modules "$p"/ "$copy"/; else cp -R "$p" "$copy"; rm -rf "$copy/.codegraph"; fi
    index_one "mine-$name" "$copy"
    # procedures called most, and the first few files whose tree contains a parse error
    node -e "
      const {DatabaseSync}=require('node:sqlite');const d=new DatabaseSync('$copy/.codegraph/codegraph.db',{readOnly:true});
      console.log('   most-called odin procedures:');
      for(const r of d.prepare(\"select n.name||' ('||n.file_path||') <- '||count(*) as s from edges e join nodes n on n.id=e.target where e.kind='calls' and n.language='odin' and n.kind='function' group by n.id order by count(*) desc limit 5\").all())console.log('     '+r.s);
      console.log('   top unresolved calls (stdlib/vendor names are expected):');
      for(const r of d.prepare(\"select reference_name||' x'||count(*) as s from unresolved_refs where reference_kind='calls' and language='odin' group by reference_name order by count(*) desc limit 8\").all())console.log('     '+r.s);
    " 2>/dev/null | tee -a "$REPORT"
  done
fi

say ""
say "== done. Paste this file back: $REPORT"
