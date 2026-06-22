#!/usr/bin/env bash
# Pure-function tests for repo-sync (no network).
set -uo pipefail
export GHQ_ROOT="/home/tester/repos"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/repo-sync"
# shellcheck disable=SC1090
source "$SCRIPT"

fail=0
check() { # desc expected actual
    if [[ "$2" == "$3" ]]; then printf 'ok   - %s\n' "$1"
    else printf 'FAIL - %s\n       expected: %q\n       actual:   %q\n' "$1" "$2" "$3"; fail=1; fi
}

check "rel_from_path"   "github.com/lmo5/dotfiles" "$(_rel_from_path /home/tester/repos/github.com/lmo5/dotfiles)"
check "folder_id"       "github.com-lmo5-dotfiles" "$(_folder_id_from_rel github.com/lmo5/dotfiles)"
check "path_from_rel"   "/home/tester/repos/github.com/lmo5/dotfiles" "$(_path_from_rel github.com/lmo5/dotfiles)"
check "url_from_rel"    "git@github.com:lmo5/dotfiles.git" "$(_url_from_rel github.com/lmo5/dotfiles)"
check "rel_from_url ssh"   "github.com/lmo5/dotfiles" "$(_rel_from_url git@github.com:lmo5/dotfiles.git)"
check "rel_from_url https" "github.com/lmo5/dotfiles" "$(_rel_from_url https://github.com/lmo5/dotfiles.git)"
check "subgroup roundtrip" "git@gitlab.com:grp/sub/repo.git" "$(_url_from_rel "$(_rel_from_url git@gitlab.com:grp/sub/repo.git)")"

exit $fail
