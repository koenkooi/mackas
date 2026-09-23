#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
shim="$root/bin/realpath"
work=$(mktemp -d)

set +e
/bin/realpath -e /bin/sh >"$work/red.out" 2>"$work/red.err"
red=$?
set -e
if [ "$red" -eq 0 ]; then
  echo "BSD realpath -e unexpectedly succeeded" >&2
  exit 1
fi
grep -q "illegal option" "$work/red.err"

got=$("$shim" -e /bin/sh)
[ -n "$got" ]
[ -e "$got" ]

set +e
"$shim" -e "$work/missing" >"$work/miss.out" 2>"$work/miss.err"
miss=$?
"$shim" -qe "$work/missing" >"$work/quiet.out" 2>"$work/quiet.err"
quiet=$?
set -e
[ "$miss" -ne 0 ]
[ "$quiet" -ne 0 ]
[ ! -s "$work/quiet.err" ]

rel=$("$shim" -q --relative-base="$work" "$work/child")
[ "$rel" = "child" ]
abs=$("$shim" -q --relative-base=/private/tmp /bin/sh)
case "$abs" in
  /*) ;;
  *) echo "expected an absolute path outside the base, got $abs" >&2; exit 1 ;;
esac

if ! grep -q 'ck_warn "Homebrew not found"' "$root/mackas"; then
  echo "Homebrew absence is still a hard failure" >&2
  exit 1
fi
echo "mackas realpath darwin ok (bsd -e exit $red, /bin/sh $got, rel $rel)"
rm -rf "$work"
