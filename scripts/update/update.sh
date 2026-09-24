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

# ---------------------------------------------------------------------------------------------
# Manifest and anchors

# Loads the manifest into ENTRIES, one compact JSON object per element.
load_manifest() {
  mapfile -t ENTRIES < <(jq -c '.[]' "$MANIFEST")
}

# Prints field $2 (a jq path such as .name or .sha256.var) of entry JSON $1, or nothing.
field() {
  jq -r "$2 // empty" <<<"$1"
}

# Prints the line number of the Dockerfile line "ARG $1=...".
arg_line() {
  grep -n -m1 -E "^ARG $1=" "$DOCKERFILE" | cut -d: -f1
}

# Prints the line number of the first "$2)" case line after line $1 that sets variable $3,
# stopping at the next ARG so one tool's lookup never lands in another tool's RUN block.
case_line() {
  awk -v start="$1" -v arch="$2)" -v set="$3=" '
    NR > start && /^ARG / { exit }
    NR > start && index($0, arch) && index($0, set) { print NR; exit }' "$DOCKERFILE"
}

# Prints the line number of Feature $1's key in devcontainer.json. $1 has no version tag, and
# matches the key with or without one: ".../node" matches ".../node:2.0" but not ".../nodejs".
feature_line() {
  awk -v exact="\"$1\":" -v tagged="\"$1:" '
    index($0, exact) || index($0, tagged) { print NR; exit }' "$DEVCONTAINER_JSON"
}

# Prints the line number of option $2 inside Feature $1's block, or nothing if the block does
# not set it.
feature_option_line() {
  local start
  start=$(feature_line "$1")
  if [[ -z $start ]]; then
    return 0
  fi
  awk -v start="$start" -v opt="\"$2\":" '
    NR == start && /}/ { exit }
    NR > start && /^[[:space:]]*}/ { exit }
    NR > start && index($0, opt) { print NR; exit }' "$DEVCONTAINER_JSON"
}

# Prints "<file>|<line>|<prefix>", the location of the value entry $1 pins: $2 is "version",
# "sha256" for a single checksum ARG, or "sha256:<arch>" for a per-arch checksum. The value is
# the text right after <prefix> on that line, optionally in double quotes. <line> is empty
# when the anchor is not in the file.
anchor() {
  local e=$1 what=$2 arg
  arg=$(field "$e" .arg)
  case "$(field "$e" .kind):$what" in
    dockerfile-arg:version)
      printf '%s|%s|%s\n' "$DOCKERFILE" "$(arg_line "$arg")" "ARG $arg=" ;;
    dockerfile-arg:sha256)
      local sha_arg
      sha_arg=$(field "$e" .sha256.arg)
      printf '%s|%s|%s\n' "$DOCKERFILE" "$(arg_line "$sha_arg")" "ARG $sha_arg=" ;;
    dockerfile-arg:sha256:*)
      local var start line=""
      var=$(field "$e" .sha256.var)
      start=$(arg_line "$arg")
      if [[ -n $start ]]; then
        line=$(case_line "$start" "${what#sha256:}" "$var")
      fi
      printf '%s|%s|%s\n' "$DOCKERFILE" "$line" "$var=" ;;
    base-image:version)
      printf '%s|%s|%s\n' "$DOCKERFILE" "$(grep -n -m1 '^FROM ' "$DOCKERFILE" | cut -d: -f1)" \
        "mcr.microsoft.com/$(field "$e" .source.image):" ;;
    feature-option:version)
      local option
      option=$(field "$e" .option)
      printf '%s|%s|%s\n' "$DEVCONTAINER_JSON" \
        "$(feature_option_line "$(field "$e" .feature)" "$option")" "\"$option\": " ;;
    feature-ref:version)
      local feature
      feature=$(field "$e" .feature)
      printf '%s|%s|%s\n' "$DEVCONTAINER_JSON" "$(feature_line "$feature")" "\"$feature:" ;;
    *)
      echo "no $what anchor for kind $(field "$e" .kind)" >&2
      return 1 ;;
  esac
}

# Prints the value at anchor $1, without quotes. Fails if the anchor is not in the file.
anchor_value() {
  local file line prefix text
  IFS='|' read -r file line prefix <<<"$1"
  if [[ -z $line ]]; then
    return 1
  fi
  text=$(sed -n "${line}p" "$file")
  if [[ $text != *"$prefix"* ]]; then
    return 1
  fi
  text=${text#*"$prefix"}
  text=${text#\"}
  [[ $text =~ ^[0-9A-Za-z.]+ ]] || return 1
  echo "${BASH_REMATCH[0]}"
}

# Replaces value $2 at anchor $1 with $3, keeping any quotes. Rewrites the file in place so its
# inode (and any bind mount of it) survives. Fails without writing if $2 is not at the anchor.
anchor_write() {
  local file line prefix old=$2 new=$3 text q=""
  local -a lines
  IFS='|' read -r file line prefix <<<"$1"
  if [[ -z $line ]]; then
    echo "cannot find ${prefix% } in $(basename "$file")" >&2
    return 1
  fi
  mapfile -t lines <"$file"
  text=${lines[line - 1]}
  if [[ $text == *"$prefix\"$old"* ]]; then
    q='"'
  elif [[ $text != *"$prefix$old"* ]]; then
    echo "expected $prefix$old on line $line of $(basename "$file")" >&2
    return 1
  fi
  lines[line - 1]=${text/"$prefix$q$old"/"$prefix$q$new"}
  printf '%s\n' "${lines[@]}" >"$file"
}

# Prints the version entry $1 currently pins. Fails if it cannot be found.
current_value() {
  local a
  a=$(anchor "$1" version) || return 1
  anchor_value "$a"
}
