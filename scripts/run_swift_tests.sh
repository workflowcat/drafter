#!/bin/zsh
# Every Swift test in tests/, one at a time, each by the compile line at the top of its file
# (`// swiftc ... && app/build/x-test`). Prints one line per file and exits 1 if any failed.
#   zsh scripts/run_swift_tests.sh [name-part ...]     # no argument = all
cd "${0:A:h:h}" || exit 1
mkdir -p app/build
fail=(); n=0
for f in tests/*.swift; do
  if (( $# )); then hit=0; for p in "$@"; do [[ $f == *$p* ]] && hit=1; done; (( hit )) || continue; fi
  line=$(head -12 "$f" | grep -m1 -E '^// *swiftc ' | sed -E 's|^// *||')
  if [[ -z $line ]]; then echo "skip  ${f:t} (no compile line)"; continue; fi
  n=$((n+1))
  if out=$(eval "$line" 2>&1); then echo "ok    ${f:t}"
  else echo "FAIL  ${f:t}: $(print -r -- "$out" | grep -m1 -E 'error:|FAIL|failed' | cut -c1-160)"; fail+=(${f:t}); fi
done
echo "swift tests: ran $n; failed: ${fail[*]}"
(( ${#fail} == 0 ))
