#!/usr/bin/env bash
#
# CLI contract smoke test: exit codes (plan Section 10.1) and stream discipline
# (Section 10.2), exercised against the real built binary.
#
# Deliberately requires no speech assets. Everything here is engine independent,
# so it gives CI something that genuinely passes or fails rather than skipping
# quietly on a runner with no models installed. The transcription path is covered
# by the unit tests, which do run the analyzer when assets are present.
#
# Usage: Scripts/smoke.sh [path-to-binary]

set -euo pipefail

BIN="${1:-.build/release/audiosearch}"
WORK="$(mktemp -d)"
DB="$WORK/index.db"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok()   { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# Runs the binary, capturing stdout, stderr and exit code separately.
run() {
  set +e
  OUT="$("$BIN" "$@" 2>"$WORK/stderr")"
  CODE=$?
  set -e
  ERR="$(cat "$WORK/stderr")"
}

expect_code() { # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1 — expected exit $2, got $3"; fi
}

expect_empty_stdout() {
  if [ -z "$OUT" ]; then ok "$1"; else bad "$1 — stdout was not empty: $(printf '%s' "$OUT" | head -c 120)"; fi
}

expect_stdout_contains() {
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1 — stdout lacked '$2'" ;; esac
}

expect_stderr_contains() {
  case "$ERR" in *"$2"*) ok "$1" ;; *) bad "$1 — stderr lacked '$2'" ;; esac
}

expect_stderr_lacks() {
  case "$ERR" in *"$2"*) bad "$1 — stderr still contained '$2'" ;; *) ok "$1" ;; esac
}

echo "smoke: $BIN"
"$BIN" --version >/dev/null

echo
echo "-- environment errors (exit 3) --"
run search --db "$WORK/does-not-exist.db" anything
expect_code "search with no index" 3 "$CODE"
expect_empty_stdout "search with no index writes nothing to stdout"

echo
echo "-- usage errors (exit 2) --"
run search --db "$DB" --all --any foo
expect_code "conflicting match modes" 2 "$CODE"
run search --db "$DB"
expect_code "empty query" 2 "$CODE"
run nosuchcommand
expect_code "unknown subcommand" 2 "$CODE"
run prune --db "$DB"
expect_code "unimplemented subcommand names its milestone" 2 "$CODE"

echo
echo "-- doctor and index setup --"
# doctor's exit code is legitimately environment dependent: 0 when everything is
# available, 3 when something is missing. A CI runner has no speech assets
# installed, so 3 is the correct answer there and asserting 0 would be asserting
# that CI has models. Both are accepted; what is NOT negotiable is that doctor
# keeps stdout clean and says which case it is.
run doctor --db "$DB"
if [ "$CODE" = "0" ] || [ "$CODE" = "3" ]; then
  ok "doctor ran and reported (exit $CODE)"
  if [ "$CODE" = "3" ]; then
    printf '        environment is incomplete, as expected on CI:\n'
    printf '%s\n' "$ERR" | sed -n 's/^  problem: /          problem: /p'
  fi
else
  bad "doctor exited $CODE, which is neither healthy (0) nor an environment problem (3)"
fi
expect_empty_stdout "doctor writes nothing to stdout"

run index --db "$DB" --set-root "$WORK"
expect_code "index --set-root" 0 "$CODE"
run index --db "$DB" --min-segment 999 --max-segment 10 "$WORK"
expect_code "contradictory segment bounds rejected" 2 "$CODE"

# Seed transcripts directly, so the search contract can be tested without models.
#
# Note what is NOT written here: segments_fts. The system sqlite3 CLI does not
# necessarily have FTS5 compiled in — the macos-26 runner's does not, and fails
# with "no such module: fts5" — even though the tool itself is fine, because GRDB
# bundles its own SQLite with FTS5 enabled (plan Risk 3). Touching only the plain
# tables keeps this script working on either. Populating the search index is then
# `doctor --repair`'s job, which conveniently exercises that path for real.
sqlite3 "$DB" <<'SQL'
INSERT INTO files(path,hash,size,mtime,duration,locale,engine,status,indexed_at)
VALUES('/Audio/ep-207.mp3','h1',100,1,1878.4,'en-US','speech/ci/en-US/seg2','ok',1),
      ('/Audio/panel.m4a','h2',100,1,3900.0,'en-US','speech/ci/en-US/seg2','ok',1);
INSERT INTO segments(file_id,t0_ms,t1_ms,text) VALUES
 (1,872340,876100,'getting started with software defined radio is cheap'),
 (1,2467000,2470000,'the software defined radio on my desk'),
 (2,3775000,3778000,'a panel on software defined radio');
SQL

# Segments exist but are not indexed, which is exactly the desynchronised state.
run doctor --db "$DB"
expect_stderr_contains "doctor sees unindexed transcripts as out of sync" "OUT OF SYNC"
run doctor --db "$DB" --repair
expect_stderr_contains "doctor --repair rebuilds the search index" "repaired"

echo
echo "-- search results (exit 0) --"
run search --db "$DB" "software defined radio"
expect_code "phrase search" 0 "$CODE"
expect_stdout_contains "results reach stdout" "/Audio/ep-207.mp3"
if [ -n "$ERR" ]; then ok "match count goes to stderr"; else bad "match count was not on stderr"; fi

run search --db "$DB" --format tsv "software defined radio"
expect_code "tsv format" 0 "$CODE"
if printf '%s' "$OUT" | head -1 | grep -q "$(printf '\t')"; then
  ok "tsv output is tab separated"
else
  bad "tsv output had no tabs"
fi
if printf '%s' "$OUT" | grep -q '^~'; then
  bad "tsv emitted a ~ path, which no other program can open"
else
  ok "tsv paths are absolute"
fi

run search --db "$DB" --format json "software defined radio"
expect_code "json format" 0 "$CODE"
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list) and len(d)==3' 2>/dev/null; then
  ok "json output parses as an array of 3 hits"
else
  bad "json output did not parse as expected"
fi

echo
echo "-- no matches (exit 1, grep convention) --"
run search --db "$DB" "nonexistent phrase here"
expect_code "no matches" 1 "$CODE"
expect_empty_stdout "no matches writes nothing to stdout"

echo
echo "-- adversarial queries must not error --"
for query in '*' '^x' 'a:b' '!!!' 'foo -bar "baz' 'NEAR(unclosed'; do
  run search --db "$DB" "$query"
  if [ "$CODE" = "0" ] || [ "$CODE" = "1" ]; then
    ok "query [$query] returned results or none, not an error"
  else
    bad "query [$query] exited $CODE"
  fi
done

echo
echo "-- status and integrity --"
run status --db "$DB"
expect_code "status" 0 "$CODE"
expect_empty_stdout "status writes nothing to stdout"

# Desynchronise the search index behind the tool's back, which the row-count
# check this project used to rely on could not detect.
#
# Asserted on doctor's findings rather than its exit code, because a runner with
# no speech assets makes doctor exit 3 for an unrelated reason. Exit codes alone
# cannot distinguish "the search index is broken" from "no models installed".
sqlite3 "$DB" "INSERT INTO segments(file_id,t0_ms,t1_ms,text) VALUES(1,0,1,'invisible orphan');"
run search --db "$DB" "invisible orphan"
expect_code "an unindexed transcript is genuinely unfindable" 1 "$CODE"

run doctor --db "$DB"
expect_stderr_contains "doctor detects a desynchronised search index" "OUT OF SYNC"

run doctor --db "$DB" --repair
expect_stderr_contains "doctor --repair reports repairing it" "repaired"

run doctor --db "$DB"
expect_stderr_lacks "the index is no longer reported out of sync" "OUT OF SYNC"

run search --db "$DB" "invisible orphan"
expect_code "the repaired text is findable" 0 "$CODE"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
