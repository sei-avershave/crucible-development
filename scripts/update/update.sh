#!/usr/bin/env bash
# Copyright 2026 Carnegie Mellon University. All Rights Reserved.
# Released under a MIT (SEI)-style license. See LICENSE.md in the project root for license information.
#
# Updates the dev container's pinned tool versions, Feature versions, in-place tools, and cloned
# Crucible repos. Run it through Task (task update, task update:check, ...; see Taskfile.yml).
# tools.json next to this script lists every item, where its versions come from, and how to edit it.
#
# Usage: update.sh all|pins|features|tools|repos|check
#
# test.sh sources this file, so everything is a function and main only runs when executed.

UPDATE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$UPDATE_DIR/../.." && pwd)
MANIFEST=${MANIFEST:-$UPDATE_DIR/tools.json}
DOCKERFILE=${DOCKERFILE:-$REPO_ROOT/.devcontainer/Dockerfile}
DEVCONTAINER_JSON=${DEVCONTAINER_JSON:-$REPO_ROOT/.devcontainer/devcontainer.json}
LOCK_JSON=${LOCK_JSON:-$REPO_ROOT/.devcontainer/devcontainer-lock.json}

# ---------------------------------------------------------------------------------------------
# Version rules

# Reads raw version strings on stdin and prints the usable ones: a leading "v" is stripped,
# anything but dot-separated integers (rc, beta, "latest") is dropped, and versions with at
# least $1 components are cut to exactly $1, so a "2.92" pin compares against "2.95", not
# "2.95.1". Output is unique and sorted oldest to newest.
ver_filter() {
  awk -v n="$1" '
    { sub(/^v/, "") }
    /^[0-9]+(\.[0-9]+)*$/ {
      if (split($0, p, ".") < n) next
      out = p[1]
      for (i = 2; i <= n; i++) out = out "." p[i]
      print out
    }' | sort -uV
}

# Prints the number of dot-separated components in version $1.
ver_parts() {
  local IFS=.
  local -a p
  read -ra p <<<"$1"
  echo "${#p[@]}"
}

# Prints the part of version $1 that must stay the same for an update to be non-major: the
# first component, or the first two for 0.x, where a minor release may break compatibility.
ver_major_key() {
  local IFS=.
  local -a p
  read -ra p <<<"$1"
  if [[ ${p[0]} == 0 && ${#p[@]} -gt 1 ]]; then
    echo "0.${p[1]}"
  else
    echo "${p[0]}"
  fi
}

# True if version $1 is newer than version $2.
ver_gt() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# Reads available versions on stdin and prints the update rows for current version $1:
# "minor <v>" for the newest version with the same major key, and "major <v>" for the newest
# overall when that is a major bump. Prints nothing when $1 is already the newest.
pick_candidates() {
  local current=$1 key v newer=false in_major="" overall=""
  key=$(ver_major_key "$current")
  while read -r v; do
    # The list is sorted, so once one version is newer than the pin, all later ones are too.
    if ! $newer; then
      ver_gt "$v" "$current" || continue
      newer=true
    fi
    overall=$v
    if [[ $(ver_major_key "$v") == "$key" ]]; then
      in_major=$v
    fi
  done < <(ver_filter "$(ver_parts "$current")")
  if [[ -n $in_major ]]; then
    echo "minor $in_major"
  fi
  if [[ -n $overall && $overall != "$in_major" ]]; then
    echo "major $overall"
  fi
}
