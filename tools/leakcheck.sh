#!/usr/bin/env bash
# Fails if anything that would be published (tracked files, and new files git doesn't ignore) holds a secret or one
# of your own values. Your values go in .leakcheck.local (git-ignored), one extended regex per line; a line starting
# with "warn:" only warns. Run `make leakcheck`; `make leakcheck-hook` runs it before every commit.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

block=(
  'sk-ant-[A-Za-z0-9_-]{10,}'            # Anthropic API keys
  'gh[pousr]_[A-Za-z0-9]{30,}' 'github_pat_[A-Za-z0-9_]{30,}'
  'tskey-[A-Za-z0-9-]{10,}'              # Tailscale auth keys
  'hf_[A-Za-z0-9]{30,}' 'AKIA[0-9A-Z]{16}' 'xox[abpr]-[A-Za-z0-9-]{10,}'
  'BEGIN ([A-Z]+ )?PRIVATE KEY'
)
warn=()
if [[ -f .leakcheck.local ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line == warn:* ]]; then warn+=("${line#warn:}"); else block+=("$line"); fi
  done < .leakcheck.local
fi

files=()
while IFS= read -r -d '' f; do [[ -f $f ]] && files+=("$f"); done < <(git ls-files -z --cached --others --exclude-standard)
fail=0
for f in "${files[@]}"; do
  case "$f" in
    *.p8|*.pem|*.key|*.mobileprovision|*.p12|*tokens.json|*local.env|*Local.xcconfig|local.mk|*fleet.local.json)
      echo "leakcheck: $f should not be published"; fail=1 ;;
  esac
done
join() { local IFS='|'; echo "$*"; }
if ((${#files[@]})); then
  if grep -InE "$(join "${block[@]}")" -- "${files[@]}"; then fail=1; fi
  if ((${#warn[@]})); then
    n=$(grep -IcE "$(join "${warn[@]}")" -- "${files[@]}" | awk -F: '{s+=$NF} END {print s+0}')
    ((n)) && echo "leakcheck: warning: $n lines match your warn: patterns (grep -rnE them to see where)"
  fi
fi
((fail)) && { echo "leakcheck: FAILED: the matches above would be published"; exit 1; }
echo "leakcheck: ok (${#files[@]} files)"
