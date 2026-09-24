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

# ---------------------------------------------------------------------------------------------
# Applying edits

# Applies version $2 to entry $1, plus the checksums in $3 ("<arch> <sha256>" lines, with "-"
# as the arch for a single checksum). Every edit is read back; if any edit fails, the file is
# restored to how it was before this item and the function fails.
apply_item() {
  local e=$1 new=$2 sums=${3:-} file snapshot
  file=$(anchor "$e" version) || return 1
  file=${file%%|*}
  snapshot=$(mktemp "$WORK/snapshot.XXXXXX")
  cp "$file" "$snapshot"
  IN_PROGRESS="$file|$snapshot"
  if apply_item_edits "$e" "$new" "$sums"; then
    IN_PROGRESS=""
    rm -f "$snapshot"
    return 0
  fi
  cat "$snapshot" >"$file"
  IN_PROGRESS=""
  rm -f "$snapshot"
  return 1
}

# The edits behind apply_item, without the restore on failure.
apply_item_edits() {
  local e=$1 new=$2 sums=$3 a old arch sum
  a=$(anchor "$e" version) || return 1
  old=$(anchor_value "$a") || { echo "cannot read the current version" >&2; return 1; }
  anchor_write "$a" "$old" "$new" || return 1
  if [[ $(anchor_value "$a") != "$new" ]]; then
    echo "version did not read back as $new" >&2
    return 1
  fi
  while read -r arch sum; do
    if [[ -z $arch ]]; then
      continue
    fi
    if [[ $arch == - ]]; then
      a=$(anchor "$e" sha256) || return 1
    else
      a=$(anchor "$e" "sha256:$arch") || return 1
    fi
    old=$(anchor_value "$a") || { echo "cannot find the ${arch/-/single} checksum" >&2; return 1; }
    anchor_write "$a" "$old" "$sum" || return 1
    if [[ $(anchor_value "$a") != "$sum" ]]; then
      echo "checksum for $arch did not read back as written" >&2
      return 1
    fi
  done <<<"$sums"
}

# Ctrl-C trap: puts back the file an edit was in progress on, then exits.
on_interrupt() {
  if [[ -n ${IN_PROGRESS:-} ]]; then
    cat "${IN_PROGRESS#*|}" >"${IN_PROGRESS%%|*}"
    echo "Interrupted; restored ${IN_PROGRESS%%|*}." >&2
  fi
  exit 130
}

# ---------------------------------------------------------------------------------------------
# Sources and verification. Tests replace fetch_versions, url_sha256, and url_exists.

# Prints the versions published for entry $1, one per line (ver_filter cleans them up).
# Fails with a message on stderr if the lookup fails.
fetch_versions() {
  local e=$1
  case $(field "$e" .source.type) in
    github-release)
      gh api "repos/$(field "$e" .source.repo)/releases?per_page=100" \
        --jq '.[] | select((.draft or .prerelease) | not) | .tag_name' ;;
    github-tag)
      gh api --paginate \
        "repos/$(field "$e" .source.repo)/git/matching-refs/tags/$(field "$e" .source.prefix)" \
        --jq '.[].ref | ltrimstr("refs/tags/")' ;;
    npm)
      npm view "$(field "$e" .source.package)" versions --json |
        jq -r 'if type == "array" then .[] else . end' ;;
    go)
      curl -fsSL 'https://go.dev/dl/?mode=json&include=all' |
        jq -r '.[] | select(.stable) | .version | ltrimstr("go")' ;;
    node)
      curl -fsSL https://nodejs.org/dist/index.json | jq -r '.[] | select(.lts) | .version' ;;
    k8s)
      curl -fsSL https://dl.k8s.io/release/stable.txt && echo ;;
    mcr)
      curl -fsSL "https://mcr.microsoft.com/v2/$(field "$e" .source.image)/tags/list" |
        jq -r --arg s "$(field "$e" .source.suffix)" '.tags[] | select(endswith($s)) | rtrimstr($s)' ;;
    ghcr)
      local image token
      image=$(field "$e" .source.image)
      token=$(curl -fsSL "https://ghcr.io/token?scope=repository:$image:pull" | jq -r .token) ||
        return 1
      curl -fsSL -H "Authorization: Bearer $token" "https://ghcr.io/v2/$image/tags/list?n=1000" |
        jq -r '.tags[]' ;;
    *)
      echo "unknown source type '$(field "$e" .source.type)'" >&2
      return 1 ;;
  esac
}

# Prints the sha256 of the file at URL $1. Downloads to a file first, so a failed download can
# never produce the checksum of an empty stream.
url_sha256() {
  local out sum
  out=$(mktemp "$WORK/download.XXXXXX")
  if ! curl -fsSL --retry 2 -o "$out" "$1"; then
    rm -f "$out"
    return 1
  fi
  sum=$(sha256sum "$out" | cut -d' ' -f1)
  rm -f "$out"
  echo "$sum"
}

# True if URL $1 can be downloaded. Fetches one byte: GitHub's signed download URLs refuse HEAD.
url_exists() {
  curl -fsSL --retry 2 -r 0-0 -o /dev/null "$1"
}

# Prints URL template $1 with {version} replaced by $2 and {arch} by $3.
render_url() {
  local url=${1//"{version}"/$2}
  echo "${url//"{arch}"/${3:-}}"
}

# Confirms entry $1 can be installed at version $2. Prints the checksums it needs as
# "<arch> <sha256>" lines ("-" as the arch for a single checksum), or nothing if it has none.
verify_candidate() {
  local e=$1 v=$2 url arch sum
  url=$(field "$e" .sha256.url)
  if [[ -n $url ]]; then
    if [[ -z $(field "$e" .sha256.arch) ]]; then
      sum=$(url_sha256 "$(render_url "$url" "$v")") || { echo "cannot download $(render_url "$url" "$v")" >&2; return 1; }
      echo "- $sum"
      return 0
    fi
    for arch in $(jq -r '.sha256.arch | keys[]' <<<"$e"); do
      url=$(render_url "$(field "$e" .sha256.url)" "$v" "$(field "$e" ".sha256.arch.$arch")")
      sum=$(url_sha256 "$url") || { echo "cannot download $url" >&2; return 1; }
      echo "$arch $sum"
    done
    return 0
  fi
  url=$(field "$e" .url)
  if [[ -z $url ]]; then
    return 0
  fi
  if [[ -z $(field "$e" .arch) ]]; then
    url_exists "$(render_url "$url" "$v")" || { echo "cannot download $(render_url "$url" "$v")" >&2; return 1; }
    return 0
  fi
  for arch in $(jq -r '.arch | keys[]' <<<"$e"); do
    url=$(render_url "$(field "$e" .url)" "$v" "$(field "$e" ".arch.$arch")")
    url_exists "$url" || { echo "cannot download $url" >&2; return 1; }
  done
}

# ---------------------------------------------------------------------------------------------
# Planning

# Prints "<minor|major> <version>" rows for entry index $1. With $2 = verify, each candidate is
# also checked by verify_candidate, its checksums saved to $WORK/sums/<index>-<version>, and a
# candidate that fails is dropped with the reason on stderr.
plan_one() {
  local i=$1 mode=${2:-} e=${ENTRIES[$1]} current versions kind v sums
  current=$(current_value "$e") || { echo "cannot find its current version" >&2; return 1; }
  if ! versions=$(fetch_versions "$e" 2>&1); then
    echo "lookup failed: ${versions##*$'\n'}" >&2
    return 1
  fi
  # A source that answers with nothing usable is misconfigured, not up to date.
  if [[ -z $(ver_filter "$(ver_parts "$current")" <<<"$versions") ]]; then
    echo "lookup found no versions" >&2
    return 1
  fi
  while read -r kind v; do
    if [[ $mode == verify ]]; then
      if ! sums=$(verify_candidate "$e" "$v" 2>&1); then
        echo "$v skipped: ${sums##*$'\n'}" >&2
        continue
      fi
      printf '%s\n' "$sums" >"$WORK/sums/$i-$v"
    fi
    echo "$kind $v"
  done < <(pick_candidates "$current" <<<"$versions")
}

# Runs plan_one (mode $1) in parallel for each entry index after the first two arguments,
# writing <dir $2>/<index>.rows and <index>.err. Held entries are not looked up.
lookup_all() {
  local mode=$1 dir=$2 i
  shift 2
  mkdir -p "$dir"
  for i in "$@"; do
    if [[ $(field "${ENTRIES[i]}" .hold) != true ]]; then
      plan_one "$i" "$mode" >"$dir/$i.rows" 2>"$dir/$i.err" &
    fi
  done
  wait
}

# Prints the manifest indexes of entries whose kind is one of the arguments.
entries_of_kind() {
  local i kind
  for i in "${!ENTRIES[@]}"; do
    kind=$(field "${ENTRIES[i]}" .kind)
    if [[ " $* " == *" $kind "* ]]; then
      echo "$i"
    fi
  done
}

# Reads chosen "<index>:<minor|major>" tags on stdin and prints "<index> <kind>" once per index,
# preferring major when both of an item's rows were chosen. Other tags are ignored.
resolve_choices() {
  awk -F: '$1 ~ /^[0-9]+$/ { if (!($1 in pick) || $2 == "major") pick[$1] = $2 }
           END { for (i in pick) print i, pick[i] }' | sort -n
}

# ---------------------------------------------------------------------------------------------
# Terminal UI. Tests replace these.

# Shows a checklist titled $1, built from the tag/label/on|off triples that follow, and prints
# the chosen tags one per line. Fails if the user presses Cancel or Esc.
dialog_checklist() {
  local title=$1
  shift
  dialog --backtitle "Crucible dev container update" --title "$title" --separate-output \
    --checklist "Space toggles an item, Enter applies. Cancel or Esc skips this step." \
    0 0 0 "$@" 2>&1 >/dev/tty
}

# Asks yes/no question $2 titled $1. Fails on No, Cancel, or Esc.
dialog_yesno() {
  dialog --backtitle "Crucible dev container update" --title "$1" --yesno "$2" 0 0 >/dev/tty
}

# Shows message $2 titled $1 until the user presses Enter.
dialog_notice() {
  dialog --backtitle "Crucible dev container update" --title "$1" --msgbox "$2" 0 0 >/dev/tty
}

clear_screen() {
  clear >/dev/tty 2>/dev/null || true
}

# Refreshes devcontainer-lock.json from the Feature versions in devcontainer.json.
refresh_lock() {
  (cd "$REPO_ROOT" && npx --yes @devcontainers/cli upgrade --workspace-folder .)
}

# Runs manifest command $1 from the repo root.
run_command() {
  (cd "$REPO_ROOT" && bash -c "$1")
}

sync_repos() {
  (cd "$REPO_ROOT" && scripts/sync-repos.sh --pull)
}

# ---------------------------------------------------------------------------------------------
# Steps. Each one adds to UPDATED, SKIPPED, FAILED, and HELD for the summary.

# Runs the pins or features step ($1): look up and verify, show the checklist, apply the choices.
run_edit_step() {
  local step=$1 title i kind v e old row label tags err sums changed=false
  local -a idx=() args=() applied=()
  local -A cand=() chosen=()
  if [[ $step == pins ]]; then
    title="Pinned tools (Dockerfile)"
    mapfile -t idx < <(entries_of_kind dockerfile-arg base-image)
  else
    title="Features (devcontainer.json)"
    mapfile -t idx < <(entries_of_kind feature-option feature-ref)
    cp "$DEVCONTAINER_JSON" "$WORK/devcontainer.json.before"
    cp "$LOCK_JSON" "$WORK/devcontainer-lock.json.before"
  fi

  echo "$title: looking up ${#idx[@]} versions..."
  lookup_all verify "$WORK/$step" "${idx[@]}"

  local -a problems=()
  for i in "${idx[@]}"; do
    e=${ENTRIES[i]}
    if [[ $(field "$e" .hold) == true ]]; then
      HELD+=("$(field "$e" .name) $(current_value "$e" || echo '?'): $(field "$e" .reason)")
      continue
    fi
    if [[ -s $WORK/$step/$i.err ]]; then
      while read -r err; do
        problems+=("$(field "$e" .name): $err")
      done <"$WORK/$step/$i.err"
    fi
    while read -r kind v; do
      cand["$i $kind"]=$v
      label="$(field "$e" .name)  $(current_value "$e") -> $v"
      if [[ $kind == major ]]; then
        args+=("$i:$kind" "$label  MAJOR" off)
      else
        args+=("$i:$kind" "$label" on)
      fi
    done <"$WORK/$step/$i.rows"
  done

  if ((${#problems[@]})); then
    SKIPPED+=("${problems[@]}")
    # Esc on the notice exits non-zero; it must not stop the run.
    dialog_notice "$title: not offered" "$(printf '%s\n' "${problems[@]}")" || true
  fi
  if [[ $step == features ]]; then
    args+=(lock "Refresh Feature lock file" off)
  elif ((${#args[@]} == 0)); then
    clear_screen
    echo "$title: everything is up to date."
    return 0
  fi

  if ! tags=$(dialog_checklist "$title" "${args[@]}"); then
    clear_screen
    SKIPPED+=("$title: cancelled")
    return 0
  fi
  clear_screen

  while read -r i kind; do
    chosen[$i]=1
    e=${ENTRIES[i]}
    v=${cand["$i $kind"]}
    old=$(current_value "$e")
    sums=$(cat "$WORK/sums/$i-$v" 2>/dev/null || true)
    # Not in $(...): a subshell would hide IN_PROGRESS from the Ctrl-C trap and die mid-edit.
    if apply_item "$e" "$v" "$sums" 2>"$WORK/apply.err"; then
      applied+=("$(field "$e" .name)  $old -> $v")
      changed=true
    else
      FAILED+=("$(field "$e" .name): $(<"$WORK/apply.err")")
    fi
  done < <(resolve_choices <<<"$tags")

  for row in "${!cand[@]}"; do
    i=${row% *}
    if [[ -z ${chosen[$i]:-} ]]; then
      chosen[$i]=0
      SKIPPED+=("$(field "${ENTRIES[i]}" .name): not chosen")
    fi
  done

  if [[ $step == features ]] && { $changed || grep -qx lock <<<"$tags"; }; then
    echo "Refreshing devcontainer-lock.json..."
    if ! refresh_lock; then
      cat "$WORK/devcontainer.json.before" >"$DEVCONTAINER_JSON"
      cat "$WORK/devcontainer-lock.json.before" >"$LOCK_JSON"
      for row in "${applied[@]}"; do
        FAILED+=("${row%%  *}: lock file refresh failed, devcontainer.json restored")
      done
      if ! $changed; then
        FAILED+=("Feature lock file: refresh failed")
      fi
      return 0
    fi
    if ! $changed; then
      UPDATED+=("Feature lock file refreshed")
    fi
  fi

  UPDATED+=("${applied[@]}")
  if $changed; then
    REBUILD=true
  fi
}

# Runs the chosen in-place updaters (manifest entries of kind "command").
run_tools() {
  local i e tags
  local -a args=()
  for i in $(entries_of_kind command); do
    e=${ENTRIES[i]}
    args+=("$i" "$(field "$e" .name)  ($(field "$e" .run))" on)
  done
  if ! tags=$(dialog_checklist "Container tools (updated in place)" "${args[@]}"); then
    clear_screen
    SKIPPED+=("Container tools: cancelled")
    return 0
  fi
  clear_screen
  for i in $tags; do
    e=${ENTRIES[i]}
    echo "==> $(field "$e" .name): $(field "$e" .run)"
    if run_command "$(field "$e" .run)"; then
      UPDATED+=("$(field "$e" .name) (in place)")
    else
      FAILED+=("$(field "$e" .name): '$(field "$e" .run)' failed")
    fi
  done
}

# Pulls every Crucible repo after a confirmation.
run_repos() {
  if ! dialog_yesno "Crucible repos" \
    "Pull every repository in scripts/repos.json and scripts/repos.local.json with scripts/sync-repos.sh --pull?"; then
    clear_screen
    SKIPPED+=("Crucible repos: cancelled")
    return 0
  fi
  clear_screen
  if sync_repos; then
    UPDATED+=("Crucible repos (git pull)")
  else
    FAILED+=("Crucible repos: scripts/sync-repos.sh --pull failed")
  fi
}

# Prints current and newest versions for every entry except commands. Fails if a lookup failed.
run_check() {
  local i e cur in_major newest status errors=0
  local -a idx
  mapfile -t idx < <(entries_of_kind dockerfile-arg base-image feature-option feature-ref)
  echo "Looking up ${#idx[@]} versions..." >&2
  lookup_all "" "$WORK/check" "${idx[@]}"
  printf '%-30s %-12s %-12s %-12s %s\n' ITEM CURRENT "IN MAJOR" NEWEST STATUS
  for i in "${idx[@]}"; do
    e=${ENTRIES[i]}
    cur=$(current_value "$e") || cur="?"
    in_major=$cur
    newest=$cur
    if [[ $(field "$e" .hold) == true ]]; then
      status="held: $(field "$e" .reason)"
    elif [[ -s $WORK/check/$i.err ]]; then
      status="error: $(tail -n1 "$WORK/check/$i.err")"
      in_major="-"
      newest="-"
      errors=1
    else
      in_major=$(awk '$1 == "minor" { print $2 }' "$WORK/check/$i.rows")
      newest=$(awk '$1 == "major" { print $2 }' "$WORK/check/$i.rows")
      if [[ -n $newest ]]; then
        status=MAJOR
      elif [[ -n $in_major ]]; then
        status=update
      else
        status="up to date"
      fi
      in_major=${in_major:-$cur}
      newest=${newest:-$in_major}
    fi
    printf '%-30s %-12s %-12s %-12s %s\n' "$(field "$e" .name)" "$cur" "$in_major" "$newest" "$status"
  done
  return "$errors"
}

# Prints the steps chosen in the top-level checklist.
choose_steps() {
  dialog_checklist "What to update" \
    pins "Pinned tools (Dockerfile)" on \
    features "Features (devcontainer.json)" on \
    tools "Container tools (updated in place)" on \
    repos "Crucible repos (git pull)" on
}

# Prints each non-empty list: title $1, then items.
print_list() {
  local title=$1
  shift
  if (($#)); then
    echo "$title:"
    printf '  %s\n' "$@"
  fi
}

print_summary() {
  echo
  print_list Updated "${UPDATED[@]}"
  print_list Skipped "${SKIPPED[@]}"
  print_list Failed "${FAILED[@]}"
  print_list Held "${HELD[@]}"
  if ((${#UPDATED[@]} + ${#SKIPPED[@]} + ${#FAILED[@]} + ${#HELD[@]} == 0)); then
    echo "Nothing to update."
  fi
  git -C "$REPO_ROOT" diff --stat -- .devcontainer || true
  if $REBUILD; then
    echo "Rebuild the dev container to use the new pins and Feature versions."
  fi
}

# ---------------------------------------------------------------------------------------------
# Entry point

# EXIT trap: removes the run's temp directory.
on_exit() {
  rm -rf "${WORK:-}"
}

main() {
  set -euo pipefail
  local step=${1:-}
  case $step in
    all | pins | features | tools | repos | check) ;;
    *)
      echo "usage: $0 all|pins|features|tools|repos|check" >&2
      exit 2 ;;
  esac
  if [[ $step != check ]] && ! [[ -t 0 && -t 1 ]]; then
    echo "update.sh $step needs an interactive terminal. For a report with no prompts, run: task update:check" >&2
    exit 1
  fi

  WORK=$(mktemp -d)
  mkdir -p "$WORK/sums"
  IN_PROGRESS=""
  trap on_exit EXIT
  trap on_interrupt INT TERM
  load_manifest
  UPDATED=() SKIPPED=() FAILED=() HELD=() REBUILD=false
  run_steps "$step"
}

# Runs step $1 (all, pins, features, tools, repos, or check) and, except for check, prints the
# summary. Fails if a chosen item failed or, for check, if a lookup failed.
run_steps() {
  local step=$1 s chosen
  if [[ $step == check ]]; then
    run_check
    return
  fi

  local -a steps=("$step")
  if [[ $step == all ]]; then
    if ! chosen=$(choose_steps); then
      clear_screen
      echo "Nothing chosen."
      return 0
    fi
    clear_screen
    mapfile -t steps <<<"$chosen"
  fi
  for s in "${steps[@]}"; do
    case $s in
      pins | features) run_edit_step "$s" ;;
      tools) run_tools ;;
      repos) run_repos ;;
    esac
  done
  print_summary
  ((${#FAILED[@]} == 0))
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
