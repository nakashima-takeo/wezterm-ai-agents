#!/usr/bin/env bash
# Test runner: invokes luajit on each test_*.lua and reports pass/fail.
set -uo pipefail

cd "$(dirname "$0")/.."

PASS=0
FAIL=0

for t in test/test_*.lua; do
  echo
  echo "================================================================"
  echo "  $t"
  echo "================================================================"
  if luajit "$t"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "================================================================"
echo "  Suites: pass=$PASS  fail=$FAIL"
echo "================================================================"
exit $FAIL
