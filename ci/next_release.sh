#!/bin/bash
# Prints the next image version from the commit messages since the newest v* tag, and writes the
# release notes to <notes file>. From 1.0.0 on, a breaking change (`type!:` or a BREAKING CHANGE
# footer) bumps the major version, `feat` the minor and `fix` or `perf` the patch. Before 1.0.0 a
# breaking change bumps the minor version and anything else the patch, so 0.Y is the line without
# breaking changes. A `Release-As: X.Y.Z` footer sets the version, for example to 1.0.0. Prints
# nothing when no commit calls for a release.
# Usage: next_release.sh <notes file>

set -euo pipefail

notes="$1"
newest="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n 1)"
if [ -z "${newest}" ]; then
  echo "First release." > "${notes}"
  echo 0.1.0
  exit 0
fi

bump=0 release_as=""
breaking=() features=() fixes=()
while IFS=$'\x1f' read -r -d '' hash subject body; do
  as="$(sed -n 's/^Release-As:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[[:space:]]*$/\1/p' <<< "${body}" | tail -n 1)"
  [ -z "${as}" ] || release_as="${as}"
  if [[ ! "${subject}" =~ ^([a-z]+)(\([^\)]*\))?(!)?:[[:space:]]+(.+)$ ]]; then
    echo "::warning title=Commit message::${hash} \"${subject}\" doesn't start with a type such as fix: or feat:, so it can't trigger a release" >&2
    continue
  fi
  type="${BASH_REMATCH[1]}"
  body="$(printf '%s' "${body}" | sed '/^Release-As:/d')"
  entry="- ${BASH_REMATCH[4]} (${hash})"
  if [ -n "${BASH_REMATCH[3]}" ] || grep -qE '^BREAKING[ -]CHANGE:' <<< "${body}"; then
    # The body says what users have to change.
    breaking+=("${entry}${body:+$'\n\n'$(sed 's/^./  &/' <<< "${body}")}")
    bump=3
    continue
  fi
  case "${type}" in
    feat) features+=("${entry}"); [ "${bump}" -ge 2 ] || bump=2 ;;
    fix | perf) fixes+=("${entry}"); [ "${bump}" -ge 1 ] || bump=1 ;;
    build | chore | ci | docs | refactor | revert | style | test) ;;
    *) echo "::warning title=Commit message::${hash} has the unknown type \"${type}\", so it can't trigger a release" >&2 ;;
  esac
done < <(git log -z --no-merges --reverse --format='%h%x1f%s%x1f%b' "${newest}..HEAD")

IFS=. read -r major minor patch <<< "${newest#v}"
if [ -n "${release_as}" ]; then
  if [ "$(printf '%s\n' "${newest#v}" "${release_as}" | sort -V | tail -n 1)" = "${release_as}" ] && [ "${release_as}" != "${newest#v}" ]; then
    IFS=. read -r major minor patch <<< "${release_as}"
    bump=0
  else
    echo "::warning title=Release-As::${release_as} is not newer than ${newest}, so it is ignored" >&2
    release_as=""
  fi
fi
[ "${bump}" -gt 0 ] || [ -n "${release_as}" ] || exit 0

[ "${major}" != 0 ] || [ "${bump}" -le 1 ] || bump=$((bump - 1))
case "${bump}" in
  3) major=$((major + 1)) minor=0 patch=0 ;;
  2) minor=$((minor + 1)) patch=0 ;;
  1) patch=$((patch + 1)) ;;
esac

section() {
  local title="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  printf '## %s\n\n' "${title}"
  printf '%s\n' "$@"
  echo
}
{
  section "Breaking changes" "${breaking[@]}"
  section "Features" "${features[@]}"
  section "Fixes" "${fixes[@]}"
} > "${notes}"
echo "${major}.${minor}.${patch}"
