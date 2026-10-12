#!/usr/bin/env bash
# Inspection only. Successful extraction and an explicit search miss are both
# required; an absent/broken tool is never evidence of provider absence.
check_production_selectors() {
  local object="$1" architecture="$2" listing="$3" search_status=0
  if ! strings "$object" > "$listing"; then
    printf 'FAIL: production %s selector extraction failed\n' "$architecture" >&2
    return 1
  fi
  rg -q -e 'testUseLicenseSender:mutationSender:|testUseStepBudget:' "$listing" || search_status=$?
  case "$search_status" in
    1) printf 'PASS: production %s root coordinator compilation and test selector absence\n' "$architecture" ;;
    0) printf 'FAIL: production %s root coordinator contains a test selector\n' "$architecture" >&2; return 1 ;;
    *) printf 'FAIL: production %s selector search failed (%s)\n' "$architecture" "$search_status" >&2; return 1 ;;
  esac
}
