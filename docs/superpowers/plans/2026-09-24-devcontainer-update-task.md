# Dev Container Update Task Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `task update` and its sub-tasks. From checklist menus, they update the dev container's Dockerfile pins, Feature versions, in-place tools, and Crucible repos, and leave edits in the working tree ready for review.

**Architecture:** A root `Taskfile.yml` holds entry points only. Each task runs `scripts/update/update.sh <step>`, which reads the manifest `scripts/update/tools.json`. The manifest says where each item's versions come from and which line of `.devcontainer/Dockerfile` or `.devcontainer/devcontainer.json` holds it. Candidates are looked up in parallel and verified (checksums come from real downloads) before the `dialog` checklist appears. Each chosen edit replaces one line in place and is read back through the same anchor. `scripts/update/test.sh` sources the engine, replaces its network, dialog, lock-refresh, and repo-sync functions with stubs, and runs every test offline against fixtures in `scripts/update/testdata/`.

**Tech Stack:** bash 5.2, go-task 3.50, dialog 1.3, jq 1.7, curl, gh, npm/npx (for `@devcontainers/cli`), mawk, GNU coreutils and diffutils. All are already in the dev container.

**Spec:** `docs/superpowers/specs/2026-09-24-devcontainer-update-task-design.md`

## Global Constraints

- Add no tools to the dev container, and do not use `gum`, `fzf`, `whiptail`, `yq`, `shellcheck`, `bats`, or `shfmt`. Use only what Tech Stack lists.
- The updater edits files and runs updaters. It never commits, pushes, or rebuilds the container.
- `devcontainer.json` is JSONC with comments. Every edit replaces a single line and leaves comments and formatting intact. Never parse and rewrite the whole file.
- Files are rewritten in place (`printf ... >file` or `cat snapshot >file`), never replaced with `mv` or `sed -i`. This keeps the inode, the same pattern that keeps single-file bind mounts such as `/etc/codex/config.toml` working.
- `set -euo pipefail` is set only inside `main` in `update.sh`, because `test.sh` sources the file.
- New `.sh` and `.yml` files start with the repo's CMU header, which is already in the code below.
- Use LF line endings. Make `update.sh` and `test.sh` executable, even though the Taskfile runs them with `bash`.
- The code blocks in this plan are final and were run in a scratch copy of the repo. Copy them exactly. Sections of `update.sh` are separated by one blank line, and every file ends with a single newline.
- `task update:test` must pass at the end of every task.
- Work on the current branch, `features/t3code`. Commit messages must not have a `Co-Authored-By` line.
- Stage only the files each commit step names. The working tree holds the developer's uncommitted GPT-6 and t3 work: `.devcontainer/devcontainer.json`, `.devcontainer/postcreate.sh`, `.devcontainer/poststart.sh`, `README.md`, and `.devcontainer/codex/gpt6.config.toml`. Never stage, check out, restore, reset, or stash those files unless the developer says to.

## Review Focus

1. **Esc on the "not offered" notice.** `dialog` returns 255 on Esc, which would stop a `set -e` run before the checklist appears. The run must go on to the checklist. Test: `test_pins_step_survives_esc_on_the_notice` (Task 5).
2. **Restores keep the developer's uncommitted edits.** A failed edit, a Ctrl-C, and a failed lock refresh all put files back. They must restore the run's own snapshot, never git's version. Tests: `test_failed_edit_restores_file` and `test_interrupt_restores_file_in_progress` (Task 3), `test_features_step_restores_both_files_when_lock_refresh_fails` (Task 5).
3. **A source that returns no usable versions.** A wrong repo, a wrong tag prefix, or a project with only prereleases must show as an error, not as "up to date". Test: `test_lookup_with_no_usable_versions_is_an_error` (Task 4).
4. **A failed download.** Piping `curl` into `sha256sum` hashes an empty stream when the download fails, and that hash would be written into the Dockerfile. A failed download must produce no checksum and a failure. Test: `test_url_sha256_hashes_the_download_and_fails_on_error` (Task 4).
5. **A new pin with no manifest entry.** A developer adds a Dockerfile `ARG FOO_VERSION` or a registry Feature but no `tools.json` entry, and `task update` silently never updates it. `task update:test` must fail. Test: `test_every_pin_in_the_real_files_has_a_manifest_entry` (Task 2).

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Taskfile.yml` (new, repo root) | Task entry points and their preconditions. No logic. |
| `scripts/update/update.sh` (new) | Engine: version rules, manifest anchors, edits, sources, verification, terminal UI, steps, summary, and `main`. |
| `scripts/update/tools.json` (new) | Manifest of the 39 real items. |
| `scripts/update/test.sh` (new) | Offline tests, stubs, and the test runner. |
| `scripts/update/testdata/` (new) | Small fixtures: `Dockerfile`, `devcontainer.json`, `devcontainer-lock.json`, `tools.json`. |
| `README.md` (modify) | A table of contents line and the "Updating the Dev Container" section. |
| `AGENTS.md` (modify line 109) | Extends the rule for adding tools. `CLAUDE.md` is a symlink to it. |

Tasks 1 to 6 each add one section to the end of `update.sh`. `test.sh` always ends with the line `run_tests "$@"`, and each task inserts its tests above that line.

### Data formats shared across tasks

- **Entry:** one compact JSON object from `tools.json` (`jq -c '.[]'`), passed as `$1` or `$e`. The array `ENTRIES` holds all of them, and an index into `ENTRIES` identifies an item everywhere.
- **Anchor:** `"<file>|<line>|<prefix>"`. The value is the text right after `<prefix>` on line `<line>`, optionally in double quotes. `<line>` is empty when the anchor is not in the file.
- **Candidate rows:** `"minor <version>"` and `"major <version>"`, printed by `pick_candidates` and `plan_one`.
- **Checksums:** `"<arch> <sha256>"` lines. Arch is `amd64` or `arm64`, or `-` for a single checksum with no arch. Each candidate's checksums are saved to `$WORK/sums/<index>-<version>`.
- **Checklist tags:**
  - Pins and Features checklists: `"<index>:<minor|major>"`, plus `lock` for the lock-refresh row.
  - Tools checklist: plain indexes.
  - Top-level checklist: `pins`, `features`, `tools`, `repos`.
- **Globals:**
  - `WORK`: the run's temp directory, with a `sums/` subdirectory.
  - `IN_PROGRESS`: `"<file>|<snapshot>"` while an item is being applied, otherwise empty.
  - `UPDATED`, `SKIPPED`, `FAILED`, `HELD`: arrays of summary lines.
  - `REBUILD`: `true` or `false`.
- **Test output:** `ok    <test>` or `FAIL  <test>` per test. Failures add indented `expected:` and `actual:` lines, or `stopped at a failing command`. `task update:test -- <text>` runs only the tests whose names contain `<text>`.

---

## Before you start

- [ ] **Step 1: Check the working tree**

Run: `git status --short`

Expected: the five uncommitted paths listed in Global Constraints, plus `docs/`. If `README.md` is modified, stop and ask the developer:

> README.md has uncommitted changes from the GPT-6/t3 work. Task 6 adds a section to it, and staging only that section needs interactive `git add -p`, which isn't available here. Do you want to commit your README changes first, or should Task 6 leave README.md uncommitted?

Follow the answer. Never commit their changes yourself unless they say so. Write down whether Task 6 stages `README.md`.

- [ ] **Step 2: Confirm the tools**

Run: `task --version; dialog --version; jq --version; bash --version | head -n1`

Expected: `3.50.0`, `Version: 1.3-20240101`, `jq-1.7`, and `GNU bash, version 5.2.21(1)-release`. On an amd64 host the bash line ends in `x86_64-pc-linux-gnu` instead of `aarch64-unknown-linux-gnu`.

- [ ] **Step 3: Commit the spec and this plan**

```bash
git add docs/superpowers/specs/2026-09-24-devcontainer-update-task-design.md docs/superpowers/plans/2026-09-24-devcontainer-update-task.md
git commit -m "docs: add design and plan for the dev container update task"
```

---

### Task 1: Test entry point, test runner, and version rules

**Files:**
- Create: `Taskfile.yml`
- Create: `scripts/update/test.sh`
- Create: `scripts/update/update.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `task update:test [-- <filter>]` runs `bash scripts/update/test.sh <filter>`.
  - `test.sh` globals and helpers:
    - `HERE`, the `scripts/update` directory.
    - `check <description> <expected> <actual>` and `check_status <description> <expected status> <command...>`. Both set `failed=1` on a mismatch.
    - `changes <old file> <new file>` prints the changed lines as `-old` and `+new`.
    - `run_tests [filter]`.
    - `setup`, which runs before each test. Task 2 replaces it.
  - `update.sh` globals: `UPDATE_DIR`, `REPO_ROOT`, `MANIFEST`, `DOCKERFILE`, `DEVCONTAINER_JSON`, `LOCK_JSON`. The last four keep a value already set in the environment, and the tests set them.
  - `update.sh` version functions:

    | Function | Behavior |
    | --- | --- |
    | `ver_filter <n>` | Reads raw versions on stdin and prints usable ones: leading `v` stripped, cut to `n` components, sorted, unique. |
    | `ver_parts <v>` | Prints the component count of `v`. |
    | `ver_major_key <v>` | Prints the part that must stay the same for a non-major update. |
    | `ver_gt <a> <b>` | Exit status 0 if `a` is newer than `b`. |
    | `pick_candidates <current>` | Reads versions on stdin and prints `minor <v>` and `major <v>` rows. |

- [ ] **Step 1: Create `Taskfile.yml` with only the test task**

Task 6 replaces this file with the full version.

```yaml
# Copyright 2026 Carnegie Mellon University. All Rights Reserved.
# Released under a MIT (SEI)-style license. See LICENSE.md in the project root for license information.
#
# Dev container maintenance tasks. Run `task --list` to see them. The update tasks are described
# in the README under "Updating the Dev Container".

version: '3'

silent: true

tasks:
  update:test:
    desc: Run the offline tests for scripts/update
    cmds:
      - bash scripts/update/test.sh {{.CLI_ARGS}}
```

- [ ] **Step 2: Write the failing tests**

Create `scripts/update/test.sh`, then run `chmod +x scripts/update/test.sh`.

```bash
#!/usr/bin/env bash
# Copyright 2026 Carnegie Mellon University. All Rights Reserved.
# Released under a MIT (SEI)-style license. See LICENSE.md in the project root for license information.
#
# Offline tests for update.sh. Run with: task update:test (or task update:test -- <part of a test
# name> to run only the matching tests).
# Sources update.sh, points it at fresh copies of testdata/ for each test, and replaces its
# network, dialog, and command functions with stubs. Each test_* function runs in a subshell.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=update.sh
source "$HERE/update.sh"

# ---------------------------------------------------------------------------------------------
# Helpers

failed=0

# check <description> <expected> <actual>
check() {
  if [[ $2 != "$3" ]]; then
    printf '    %s\n      expected: %s\n      actual:   %s\n' "$1" "${2//$'\n'/$'\n'                }" \
      "${3//$'\n'/$'\n'                }"
    failed=1
  fi
}

# check_status <description> <expected exit status> <command...>
check_status() {
  local description=$1 expected=$2 actual
  shift 2
  "$@" >/dev/null 2>&1 && actual=0 || actual=$?
  check "$description (exit status)" "$expected" "$actual"
}

# Prints the lines that differ between files $1 and $2 as "-old" and "+new", no line numbers.
changes() {
  diff --unchanged-line-format= --old-line-format='-%L' --new-line-format='+%L' "$1" "$2"
}

# Runs every test_* function, or only those whose names contain $1, and fails if any fails. Each
# test runs in a subshell under set -e, like main, so a command that would stop a real run also
# stops the test. (A subshell in an "if" condition would ignore set -e, hence the $? check.)
run_tests() {
  local t status=0
  for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    if [[ -n ${1:-} && $t != *"$1"* ]]; then
      continue
    fi
    (
      setup
      trap 'rc=$?; rm -rf "$WORK"; if ((rc && !failed)); then echo "    stopped at a failing command"; fi' EXIT
      set -e
      "$t"
      exit "$failed"
    )
    if (($? == 0)); then
      echo "ok    $t"
    else
      echo "FAIL  $t"
      status=1
    fi
  done
  return "$status"
}

# Gives each test a fresh work directory.
setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/sums"
}

# ---------------------------------------------------------------------------------------------
# Version rules

test_ver_filter_drops_prereleases_and_short_versions() {
  check "3 components" $'1.2.3\n1.10.0' \
    "$(printf '%s\n' v1.2.3 1.2.4-rc.1 latest 1.2 v1.10.0 1.2.3 | ver_filter 3)"
}

test_ver_filter_cuts_to_pin_granularity() {
  check "2 components" $'2.92\n2.95\n3.0' \
    "$(printf '%s\n' 2.92.0 2.92.1 2.95.0 3.0.0 | ver_filter 2)"
}

test_ver_major_key() {
  check "2.92" 2 "$(ver_major_key 2.92)"
  check "0.9.1" 0.9 "$(ver_major_key 0.9.1)"
  check "0.0.42" 0.0 "$(ver_major_key 0.0.42)"
  check "1" 1 "$(ver_major_key 1)"
}

test_ver_gt_compares_numerically() {
  check_status "1.10 > 1.9" 0 ver_gt 1.10 1.9
  check_status "1.9 > 1.10" 1 ver_gt 1.9 1.10
  check_status "1.9 > 1.9" 1 ver_gt 1.9 1.9
}

test_pick_minor_only() {
  check "rows" "minor 18.3.0" "$(printf '%s\n' v18.2.7 v18.3.0 | pick_candidates 18.2.7)"
}

test_pick_minor_and_major_keeps_granularity() {
  check "rows" $'minor 24.16\nmajor 26.0' \
    "$(printf '%s\n' v24.15.0 v24.16.1 v26.0.0 v22.9.0 | pick_candidates 24.15)"
}

test_pick_major_only() {
  check "rows" "major 30.0.0" "$(printf '%s\n' v29.4.1 v30.0.0 | pick_candidates 29.4.1)"
}

test_pick_zero_x_minor_counts_as_major() {
  check "rows" $'minor 0.9.2\nmajor 0.10.0' \
    "$(printf '%s\n' 0.9.1 0.9.2 0.10.0 | pick_candidates 0.9.1)"
}

test_pick_nothing_when_up_to_date() {
  check "rows" "" "$(printf '%s\n' 3.49.0 3.50.0 | pick_candidates 3.50.0)"
}

test_pick_nothing_when_pin_is_newer_than_all() {
  check "rows" "" "$(printf '%s\n' 4.8 4.9 | pick_candidates 5.0)"
}

test_pick_single_component_feature_ref() {
  check "rows" "major 2" "$(printf '%s\n' 1 1.0 1.0.6 2 2.0 2.0.0 latest | pick_candidates 1)"
}

run_tests "$@"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `task update:test`

Expected: FAIL with 2 `ok` and 9 `FAIL` lines, ending in `task: Failed to run task "update:test": exit status 1`. The first lines are `scripts/update/test.sh: line 14: .../scripts/update/update.sh: No such file or directory` and `...: pick_candidates: command not found`. The two `test_pick_nothing_*` tests pass only because they expect empty output.

- [ ] **Step 4: Write the version rules**

Create `scripts/update/update.sh`, then run `chmod +x scripts/update/update.sh`.

```bash
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `task update:test && bash -n scripts/update/update.sh`

Expected: 11 `ok` lines and no `FAIL`.

- [ ] **Step 6: Commit**

```bash
git add Taskfile.yml scripts/update/test.sh scripts/update/update.sh
git commit -m "feat(update): add version rules and offline test runner"
```

---

### Task 2: Manifest, fixtures, and anchors

**Files:**
- Create: `scripts/update/testdata/Dockerfile`
- Create: `scripts/update/testdata/devcontainer.json`
- Create: `scripts/update/testdata/devcontainer-lock.json`
- Create: `scripts/update/testdata/tools.json`
- Create: `scripts/update/tools.json`
- Modify: `scripts/update/test.sh` (replace `setup`, insert tests)
- Modify: `scripts/update/update.sh` (append a section)

**Interfaces:**
- Consumes (Task 1): `check`, `check_status`, `changes`, `run_tests`, `HERE`, and the path globals.
- Produces (`update.sh`):

  | Function | Behavior |
  | --- | --- |
  | `load_manifest` | Fills `ENTRIES` from `$MANIFEST`. |
  | `field <entry> <jq path>` | Prints the field (for example `.name` or `.sha256.var`), or nothing. |
  | `arg_line <name>` | Prints the Dockerfile line number of `ARG <name>=`. |
  | `case_line <from line> <arch> <var>` | Prints the line of the first `<arch>)` case that sets `<var>` after `<from line>`, stopping at the next `ARG`. |
  | `feature_line <feature>` | Prints the line of the Feature key, matched with or without a tag. |
  | `feature_option_line <feature> <option>` | Prints the option's line inside the Feature's block, or nothing. |
  | `anchor <entry> version\|sha256\|sha256:<arch>` | Prints the anchor. |
  | `anchor_value <anchor>` | Prints the unquoted value. Fails if the anchor is missing. |
  | `anchor_write <anchor> <old> <new>` | Replaces `<old>` with `<new>` in place. Fails without writing if `<old>` is not there. |
  | `current_value <entry>` | Prints the version the entry pins. |

- Produces (`test.sh`):
  - The full `setup`:
    - copies the fixtures into `$WORK` and points the path globals at them;
    - loads the fixture manifest;
    - resets `UPDATED`, `SKIPPED`, `FAILED`, `HELD`, `REBUILD`, and `IN_PROGRESS`;
    - saves `$WORK/Dockerfile.orig` and `$WORK/devcontainer.json.orig`.
  - `entry <name>` prints a fixture entry's JSON, and `index_of <name>` prints its index.
  - `SHA_A`, `SHA_B`, `SHA_C`, `SHA_1`, `SHA_2`, `SHA_3`: 64-character fake checksums.

- [ ] **Step 1: Create the fixtures**

`scripts/update/testdata/Dockerfile`:

```dockerfile
# Fixture for test.sh: the Dockerfile shapes tools.json anchors into, and nothing else.
FROM mcr.microsoft.com/devcontainers/dotnet:2.0.5-10.0-noble

ARG TARGETARCH
ARG AWS_CLI_VERSION="2.32.9"

ARG COMPOSER_VERSION=2.10.3
ARG COMPOSER_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
RUN echo composer

ARG OMP_VERSION=18.2.7
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) OMP_ARCH="x64"; OMP_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;; \
    arm64) OMP_ARCH="arm64"; OMP_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;; \
    *)     echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    echo omp

ARG VALE_VERSION=3.12.0
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64)  VALE_ARCH="64-bit" ;; \
    arm64)  VALE_ARCH="arm64" ;; \
    esac
```

`scripts/update/testdata/devcontainer.json`:

```jsonc
{
  "name": "Fixture for test.sh",
  // Comments like this one must survive every edit.
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2.5": {
      "configureZshAsDefaultShell": true
    },
    "ghcr.io/devcontainers/features/dotnet:2.5": {
      "version": "8.0"
    },
    "ghcr.io/devcontainers/features/terraform:1.4": {
      "version": "1.15",
      "tflint": "0.62.0"
    },
    "ghcr.io/devcontainers/features/node:2.0": {
      "version": "24.15", // trailing comments survive too
      "installYarnUsingApt": false
    },
    "ghcr.io/jaggedmountain/k-alias/k-alias:1": {},
    "./features/aspire": {
      "version": "13.5"
    }
  }
}
```

`scripts/update/testdata/devcontainer-lock.json`:

```json
{
  "features": {}
}
```

`scripts/update/testdata/tools.json`:

```json
[
  {
    "name": "base image",
    "kind": "base-image",
    "source": { "type": "mcr", "image": "devcontainers/dotnet", "suffix": "-10.0-noble" }
  },
  {
    "name": "AWS CLI",
    "kind": "dockerfile-arg",
    "arg": "AWS_CLI_VERSION",
    "source": { "type": "github-tag", "repo": "aws/aws-cli", "prefix": "2." },
    "url": "https://example.test/awscli-exe-linux-{arch}-{version}.zip",
    "arch": { "amd64": "x86_64", "arm64": "aarch64" }
  },
  {
    "name": "Composer",
    "kind": "dockerfile-arg",
    "arg": "COMPOSER_VERSION",
    "source": { "type": "github-release", "repo": "composer/composer" },
    "sha256": { "arg": "COMPOSER_SHA256", "url": "https://example.test/composer/{version}/composer.phar" }
  },
  {
    "name": "omp",
    "kind": "dockerfile-arg",
    "arg": "OMP_VERSION",
    "source": { "type": "github-release", "repo": "can1357/oh-my-pi" },
    "sha256": {
      "var": "OMP_SHA256",
      "url": "https://example.test/omp/v{version}/omp-linux-{arch}",
      "arch": { "amd64": "x64", "arm64": "arm64" }
    }
  },
  {
    "name": "Vale",
    "kind": "dockerfile-arg",
    "arg": "VALE_VERSION",
    "source": { "type": "github-release", "repo": "errata-ai/vale" }
  },
  {
    "name": ".NET SDK (extra)",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/dotnet",
    "option": "version",
    "hold": true,
    "reason": "kept on 8.0 on purpose"
  },
  {
    "name": "Terraform",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/terraform",
    "option": "version",
    "source": { "type": "github-release", "repo": "hashicorp/terraform" }
  },
  {
    "name": "TFLint",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/terraform",
    "option": "tflint",
    "source": { "type": "github-release", "repo": "terraform-linters/tflint" }
  },
  {
    "name": "Node.js",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/node",
    "option": "version",
    "source": { "type": "node" }
  },
  {
    "name": "Aspire CLI",
    "kind": "feature-option",
    "feature": "./features/aspire",
    "option": "version",
    "source": { "type": "github-release", "repo": "microsoft/aspire" }
  },
  {
    "name": "node Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/node",
    "source": { "type": "ghcr", "image": "devcontainers/features/node" }
  },
  {
    "name": "k-alias Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/jaggedmountain/k-alias/k-alias",
    "source": { "type": "ghcr", "image": "jaggedmountain/k-alias/k-alias" }
  },
  { "name": "Tool A", "kind": "command", "run": "echo tool-a-ran" },
  { "name": "Tool B", "kind": "command", "run": "exit 3" }
]
```

- [ ] **Step 2: Replace the minimal `setup` in `test.sh`**

Replace this block:

```bash
# Gives each test a fresh work directory.
setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/sums"
}
```

with:

```bash
# Gives each test fresh copies of the fixture files and empty summary lists.
setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/sums"
  cp "$HERE/testdata/Dockerfile" "$HERE/testdata/devcontainer.json" \
    "$HERE/testdata/devcontainer-lock.json" "$WORK/"
  DOCKERFILE=$WORK/Dockerfile
  DEVCONTAINER_JSON=$WORK/devcontainer.json
  LOCK_JSON=$WORK/devcontainer-lock.json
  MANIFEST=$HERE/testdata/tools.json
  load_manifest
  UPDATED=() SKIPPED=() FAILED=() HELD=() REBUILD=false IN_PROGRESS=""
  cp "$DOCKERFILE" "$WORK/Dockerfile.orig"
  cp "$DEVCONTAINER_JSON" "$WORK/devcontainer.json.orig"
}
```

- [ ] **Step 3: Write the failing tests**

Insert this above the last line of `scripts/update/test.sh` (`run_tests "$@"`), with one blank line on each side:

```bash
# Prints the manifest entry named $1, and its index.
entry() { jq -c --arg n "$1" '.[] | select(.name == $n)' "$MANIFEST"; }
index_of() { jq --arg n "$1" 'map(.name) | index($n)' "$MANIFEST"; }

SHA_A=$(printf 'a%.0s' {1..64})
SHA_B=$(printf 'b%.0s' {1..64})
SHA_C=$(printf 'c%.0s' {1..64})
SHA_1=$(printf '1%.0s' {1..64})
SHA_2=$(printf '2%.0s' {1..64})
SHA_3=$(printf '3%.0s' {1..64})

# ---------------------------------------------------------------------------------------------
# Manifest and anchors

test_reads_every_fixture_value() {
  local name
  declare -A want=(
    ["base image"]=2.0.5 ["AWS CLI"]=2.32.9 [Composer]=2.10.3 [omp]=18.2.7 [Vale]=3.12.0
    [".NET SDK (extra)"]=8.0 [Terraform]=1.15 [TFLint]=0.62.0 [Node.js]=24.15
    ["Aspire CLI"]=13.5 ["node Feature"]=2.0 ["k-alias Feature"]=1
  )
  for name in "${!want[@]}"; do
    check "$name" "${want[$name]}" "$(current_value "$(entry "$name")")"
  done
}

test_reads_checksums() {
  check "omp amd64" "$SHA_A" "$(anchor_value "$(anchor "$(entry omp)" sha256:amd64)")"
  check "omp arm64" "$SHA_B" "$(anchor_value "$(anchor "$(entry omp)" sha256:arm64)")"
  check "composer" "$SHA_C" "$(anchor_value "$(anchor "$(entry Composer)" sha256)")"
}

test_option_lookup_stays_inside_its_feature_block() {
  # common-utils has no "version" option; the lookup must not find node's or terraform's.
  local e='{"kind":"feature-option","feature":"ghcr.io/devcontainers/features/common-utils","option":"version"}'
  check_status "common-utils version" 1 current_value "$e"
}

test_feature_names_match_exactly() {
  local e='{"kind":"feature-ref","feature":"ghcr.io/devcontainers/features/no"}'
  check_status "prefix of node" 1 current_value "$e"
}

test_every_pin_in_the_real_files_has_a_manifest_entry() {
  local arg feature real=$UPDATE_DIR/tools.json
  for arg in $(grep -oE '^ARG [A-Z0-9_]+_VERSION=' "$REPO_ROOT/.devcontainer/Dockerfile" | cut -c5- | tr -d =); do
    check "$arg has a tools.json entry" true "$(jq --arg a "$arg" 'any(.[]; .arg == $a)' "$real")"
  done
  for feature in $(grep -oE '"ghcr\.io/[^"]+:[0-9.]+"' "$REPO_ROOT/.devcontainer/devcontainer.json" |
    tr -d '"' | sed 's/:[0-9.]*$//'); do
    check "$feature has a feature-ref entry" true \
      "$(jq --arg f "$feature" 'any(.[]; .kind == "feature-ref" and .feature == $f)' "$real")"
  done
}

test_case_line_lookup_stops_at_next_arg() {
  # Vale's RUN block has no VALE_SHA256; the lookup must not wander into another block.
  local e='{"kind":"dockerfile-arg","arg":"COMPOSER_VERSION","sha256":{"var":"OMP_SHA256"}}'
  check_status "OMP_SHA256 after COMPOSER_VERSION" 1 anchor_value "$(anchor "$e" sha256:amd64)"
}

test_real_manifest_matches_real_files() {
  local e name kind n=0
  MANIFEST=$UPDATE_DIR/tools.json
  DOCKERFILE=$REPO_ROOT/.devcontainer/Dockerfile
  DEVCONTAINER_JSON=$REPO_ROOT/.devcontainer/devcontainer.json
  load_manifest
  check "unique names" "" "$(jq -r '.[].name' "$MANIFEST" | sort | uniq -d)"
  for e in "${ENTRIES[@]}"; do
    n=$((n + 1))
    name=$(field "$e" .name)
    kind=$(field "$e" .kind)
    if [[ $kind == command ]]; then
      check "$name has run" true "$(jq 'has("run")' <<<"$e")"
      continue
    fi
    if ! current_value "$e" >/dev/null; then
      check "$name current value" "a version" "not found"
    fi
    if [[ $(field "$e" .hold) != true ]]; then
      check "$name source" true \
        "$(jq '.source.type | IN("github-release","github-tag","npm","go","node","k8s","mcr","ghcr")' <<<"$e")"
    fi
    if [[ -n $(field "$e" .sha256.arg) ]]; then
      [[ $(anchor_value "$(anchor "$e" sha256)") =~ ^[0-9a-f]{64}$ ]] ||
        check "$name checksum" "64 hex digits" "$(anchor_value "$(anchor "$e" sha256)")"
    fi
    if [[ -n $(field "$e" .sha256.var) ]]; then
      local arch
      for arch in $(jq -r '.sha256.arch | keys[]' <<<"$e"); do
        [[ $(anchor_value "$(anchor "$e" "sha256:$arch")") =~ ^[0-9a-f]{64}$ ]] ||
          check "$name $arch checksum" "64 hex digits" "$(anchor_value "$(anchor "$e" "sha256:$arch")")"
      done
    fi
  done
  check "entries checked" "$(jq length "$MANIFEST")" "$n"
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `task update:test`

Expected: FAIL with 11 `ok` and 7 `FAIL` lines. Every test prints `scripts/update/test.sh: line 79: load_manifest: command not found`. The manifest tests also print `anchor: command not found`, and the real-file tests print `jq: error: Could not open file .../scripts/update/tools.json`.

- [ ] **Step 5: Write the manifest and anchor section**

Append this to the end of `scripts/update/update.sh`:

```bash
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
```

Create `scripts/update/tools.json`:

```json
[
  {
    "name": "base image",
    "kind": "base-image",
    "source": { "type": "mcr", "image": "devcontainers/dotnet", "suffix": "-10.0-noble" }
  },
  {
    "name": "AWS CLI",
    "kind": "dockerfile-arg",
    "arg": "AWS_CLI_VERSION",
    "source": { "type": "github-tag", "repo": "aws/aws-cli", "prefix": "2." },
    "url": "https://awscli.amazonaws.com/awscli-exe-linux-{arch}-{version}.zip",
    "arch": { "amd64": "x86_64", "arm64": "aarch64" }
  },
  {
    "name": "Composer",
    "kind": "dockerfile-arg",
    "arg": "COMPOSER_VERSION",
    "source": { "type": "github-release", "repo": "composer/composer" },
    "sha256": {
      "arg": "COMPOSER_SHA256",
      "url": "https://github.com/composer/composer/releases/download/{version}/composer.phar"
    }
  },
  {
    "name": "Vale",
    "kind": "dockerfile-arg",
    "arg": "VALE_VERSION",
    "source": { "type": "github-release", "repo": "errata-ai/vale" },
    "url": "https://github.com/errata-ai/vale/releases/download/v{version}/vale_{version}_Linux_{arch}.tar.gz",
    "arch": { "amd64": "64-bit", "arm64": "arm64" }
  },
  {
    "name": "omp",
    "kind": "dockerfile-arg",
    "arg": "OMP_VERSION",
    "source": { "type": "github-release", "repo": "can1357/oh-my-pi" },
    "sha256": {
      "var": "OMP_SHA256",
      "url": "https://github.com/can1357/oh-my-pi/releases/download/v{version}/omp-linux-{arch}",
      "arch": { "amd64": "x64", "arm64": "arm64" }
    }
  },
  {
    "name": "herdr",
    "kind": "dockerfile-arg",
    "arg": "HERDR_VERSION",
    "source": { "type": "github-release", "repo": "herdrdev/herdr" },
    "sha256": {
      "var": "HERDR_SHA256",
      "url": "https://github.com/herdrdev/herdr/releases/download/v{version}/herdr-linux-{arch}",
      "arch": { "amd64": "x86_64", "arm64": "aarch64" }
    }
  },
  {
    "name": "t3code",
    "kind": "dockerfile-arg",
    "arg": "T3CODE_VERSION",
    "source": { "type": "github-release", "repo": "pingdotgg/t3code" },
    "sha256": {
      "var": "T3_SHA256",
      "url": "https://github.com/pingdotgg/t3code/releases/download/v{version}/t3-{version}-linux-{arch}.tar.gz",
      "arch": { "amd64": "x64", "arm64": "arm64" }
    }
  },
  {
    "name": "kubefwd",
    "kind": "dockerfile-arg",
    "arg": "KUBEFWD_VERSION",
    "source": { "type": "github-release", "repo": "txn2/kubefwd" },
    "url": "https://github.com/txn2/kubefwd/releases/download/v{version}/kubefwd_Linux_{arch}.tar.gz",
    "arch": { "amd64": "x86_64", "arm64": "arm64" }
  },
  {
    "name": "markdownlint-cli2",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers-extra/features/markdownlint-cli2",
    "option": "version",
    "source": { "type": "npm", "package": "markdownlint-cli2" }
  },
  {
    "name": "GitHub CLI",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/github-cli",
    "option": "version",
    "source": { "type": "github-release", "repo": "cli/cli" }
  },
  {
    "name": ".NET SDK (extra)",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/dotnet",
    "option": "version",
    "hold": true,
    "reason": "The base image supplies .NET 10; this Feature adds .NET 8 on purpose."
  },
  {
    "name": "Terraform",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/terraform",
    "option": "version",
    "source": { "type": "github-release", "repo": "hashicorp/terraform" }
  },
  {
    "name": "TFLint",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/terraform",
    "option": "tflint",
    "source": { "type": "github-release", "repo": "terraform-linters/tflint" }
  },
  {
    "name": "Terragrunt",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/terraform",
    "option": "terragrunt",
    "source": { "type": "github-release", "repo": "gruntwork-io/terragrunt" }
  },
  {
    "name": "Go",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/go",
    "option": "version",
    "source": { "type": "go" }
  },
  {
    "name": "Task",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers-extra/features/go-task",
    "option": "version",
    "source": { "type": "github-release", "repo": "go-task/task" }
  },
  {
    "name": "Docker",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/docker-in-docker",
    "option": "version",
    "source": { "type": "github-tag", "repo": "docker/cli", "prefix": "v" }
  },
  {
    "name": "kubectl",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/kubectl-helm-minikube",
    "option": "version",
    "source": { "type": "k8s" }
  },
  {
    "name": "Helm",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/kubectl-helm-minikube",
    "option": "helm",
    "source": { "type": "github-release", "repo": "helm/helm" }
  },
  {
    "name": "Node.js",
    "kind": "feature-option",
    "feature": "ghcr.io/devcontainers/features/node",
    "option": "version",
    "source": { "type": "node" }
  },
  {
    "name": "Playwright CLI",
    "kind": "feature-option",
    "feature": "./features/playwright-cli",
    "option": "version",
    "source": { "type": "npm", "package": "@playwright/cli" }
  },
  {
    "name": "Aspire CLI",
    "kind": "feature-option",
    "feature": "./features/aspire",
    "option": "version",
    "source": { "type": "github-release", "repo": "microsoft/aspire" }
  },
  {
    "name": "common-utils Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/common-utils",
    "source": { "type": "ghcr", "image": "devcontainers/features/common-utils" }
  },
  {
    "name": "markdownlint-cli2 Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers-extra/features/markdownlint-cli2",
    "source": { "type": "ghcr", "image": "devcontainers-extra/features/markdownlint-cli2" }
  },
  {
    "name": "github-cli Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/github-cli",
    "source": { "type": "ghcr", "image": "devcontainers/features/github-cli" }
  },
  {
    "name": "dotnet Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/dotnet",
    "source": { "type": "ghcr", "image": "devcontainers/features/dotnet" }
  },
  {
    "name": "terraform Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/terraform",
    "source": { "type": "ghcr", "image": "devcontainers/features/terraform" }
  },
  {
    "name": "go Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/go",
    "source": { "type": "ghcr", "image": "devcontainers/features/go" }
  },
  {
    "name": "go-task Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers-extra/features/go-task",
    "source": { "type": "ghcr", "image": "devcontainers-extra/features/go-task" }
  },
  {
    "name": "docker-in-docker Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/docker-in-docker",
    "source": { "type": "ghcr", "image": "devcontainers/features/docker-in-docker" }
  },
  {
    "name": "kubectl-helm-minikube Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/kubectl-helm-minikube",
    "source": { "type": "ghcr", "image": "devcontainers/features/kubectl-helm-minikube" }
  },
  {
    "name": "node Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/devcontainers/features/node",
    "source": { "type": "ghcr", "image": "devcontainers/features/node" }
  },
  {
    "name": "k-alias Feature",
    "kind": "feature-ref",
    "feature": "ghcr.io/jaggedmountain/k-alias/k-alias",
    "source": { "type": "ghcr", "image": "jaggedmountain/k-alias/k-alias" }
  },
  { "name": "Claude Code", "kind": "command", "run": "claude update" },
  { "name": "Codex", "kind": "command", "run": "codex update" },
  { "name": "Angular CLI", "kind": "command", "run": "npm install -g @angular/cli@latest" },
  { "name": "dotnet-ef", "kind": "command", "run": "dotnet tool update --global dotnet-ef --version '10.*'" },
  { "name": "gh-stack", "kind": "command", "run": "gh extension upgrade gh-stack" },
  { "name": "moodle-cs", "kind": "command", "run": "composer global update moodlehq/moodle-cs" }
]
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `task update:test`

Expected: 18 `ok` lines and no `FAIL`.

- [ ] **Step 7: Commit**

```bash
git add scripts/update/testdata scripts/update/tools.json scripts/update/test.sh scripts/update/update.sh
git commit -m "feat(update): add manifest, fixtures, and line anchors"
```

---

### Task 3: Applying edits

**Files:**
- Modify: `scripts/update/test.sh` (insert tests)
- Modify: `scripts/update/update.sh` (append a section)

**Interfaces:**
- Consumes (Task 2): `anchor`, `anchor_value`, `anchor_write`, `current_value`, `entry`, the `SHA_*` constants, `WORK`, and `IN_PROGRESS`.
- Produces:
  - `apply_item <entry> <version> [checksums]`:
    - Snapshots the file.
    - Writes the version and each checksum, reading each one back.
    - On any failure, restores the snapshot and returns 1, with the reason on stderr.
    - Sets `IN_PROGRESS="<file>|<snapshot>"` while it runs.
  - `apply_item_edits` is internal: the edits without the restore.
  - `on_interrupt` is the INT/TERM trap. It restores `IN_PROGRESS` if one is set, then exits 130.

- [ ] **Step 1: Write the failing tests**

Insert this above `run_tests "$@"` in `scripts/update/test.sh`, with one blank line on each side:

```bash
# ---------------------------------------------------------------------------------------------
# Applying edits

test_apply_per_arch_checksums() {
  apply_item "$(entry omp)" 18.3.0 $'amd64 '"$SHA_1"$'\narm64 '"$SHA_2"
  check "diff" "-ARG OMP_VERSION=18.2.7
+ARG OMP_VERSION=18.3.0
-    amd64) OMP_ARCH=\"x64\"; OMP_SHA256=\"$SHA_A\" ;; \\
-    arm64) OMP_ARCH=\"arm64\"; OMP_SHA256=\"$SHA_B\" ;; \\
+    amd64) OMP_ARCH=\"x64\"; OMP_SHA256=\"$SHA_1\" ;; \\
+    arm64) OMP_ARCH=\"arm64\"; OMP_SHA256=\"$SHA_2\" ;; \\" \
    "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_quoted_arg_keeps_quotes() {
  apply_item "$(entry "AWS CLI")" 2.33.0 ""
  check "diff" $'-ARG AWS_CLI_VERSION="2.32.9"\n+ARG AWS_CLI_VERSION="2.33.0"' \
    "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_single_checksum() {
  apply_item "$(entry Composer)" 2.10.4 "- $SHA_3"
  check "diff" "-ARG COMPOSER_VERSION=2.10.3
-ARG COMPOSER_SHA256=$SHA_C
+ARG COMPOSER_VERSION=2.10.4
+ARG COMPOSER_SHA256=$SHA_3" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_base_image_keeps_suffix() {
  apply_item "$(entry "base image")" 2.1.0 ""
  check "diff" $'-FROM mcr.microsoft.com/devcontainers/dotnet:2.0.5-10.0-noble\n+FROM mcr.microsoft.com/devcontainers/dotnet:2.1.0-10.0-noble' \
    "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_apply_option_keeps_trailing_comment() {
  apply_item "$(entry Node.js)" 24.16 ""
  check "diff" $'-      "version": "24.15", // trailing comments survive too\n+      "version": "24.16", // trailing comments survive too' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_second_option_in_shared_block() {
  apply_item "$(entry TFLint)" 0.63.0 ""
  check "diff" $'-      "tflint": "0.62.0"\n+      "tflint": "0.63.0"' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_ref_then_option_in_same_feature() {
  apply_item "$(entry "node Feature")" 2.1 ""
  apply_item "$(entry Node.js)" 24.16 ""
  check "diff" '-    "ghcr.io/devcontainers/features/node:2.0": {
-      "version": "24.15", // trailing comments survive too
+    "ghcr.io/devcontainers/features/node:2.1": {
+      "version": "24.16", // trailing comments survive too' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_ref_on_empty_block() {
  apply_item "$(entry "k-alias Feature")" 2 ""
  check "diff" $'-    "ghcr.io/jaggedmountain/k-alias/k-alias:1": {},\n+    "ghcr.io/jaggedmountain/k-alias/k-alias:2": {},' \
    "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_apply_keeps_inode() {
  local before
  before=$(stat -c %i "$DOCKERFILE")
  apply_item "$(entry Vale)" 3.13.0 ""
  check "inode" "$before" "$(stat -c %i "$DOCKERFILE")"
}

test_failed_edit_restores_file() {
  # Drop the arm64 checksum line so the second checksum edit fails after the version edit.
  sed -i '/arm64) OMP_ARCH/d' "$DOCKERFILE"
  cp "$DOCKERFILE" "$WORK/Dockerfile.broken"
  check_status "apply" 1 apply_item "$(entry omp)" 18.3.0 $'amd64 '"$SHA_1"$'\narm64 '"$SHA_2"
  check "file unchanged" "" "$(changes "$WORK/Dockerfile.broken" "$DOCKERFILE")"
  check "no snapshot left" "" "$(ls "$WORK" | grep snapshot)"
}

test_interrupt_restores_file_in_progress() {
  cp "$DOCKERFILE" "$WORK/snapshot.test"
  echo "half-written" >"$DOCKERFILE"
  IN_PROGRESS="$DOCKERFILE|$WORK/snapshot.test"
  check_status "on_interrupt" 130 on_interrupt_in_subshell
  check "file restored" "" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}
on_interrupt_in_subshell() { (on_interrupt); }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `task update:test`

Expected: FAIL with 18 `ok` and 11 `FAIL` lines. The failures print `apply_item: command not found` and `stopped at a failing command`.

- [ ] **Step 3: Write the edit section**

Append this to the end of `scripts/update/update.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `task update:test`

Expected: 29 `ok` lines and no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add scripts/update/test.sh scripts/update/update.sh
git commit -m "feat(update): apply anchored in-place edits with per-item rollback"
```

---

### Task 4: Sources, verification, and planning

**Files:**
- Modify: `scripts/update/test.sh` (insert stubs and tests)
- Modify: `scripts/update/update.sh` (append a section)

**Interfaces:**
- Consumes (Tasks 1 to 3): `ver_filter`, `ver_parts`, `pick_candidates`, `field`, `current_value`, `ENTRIES`, and `WORK`.
- Produces (`update.sh`):

  | Function | Behavior |
  | --- | --- |
  | `fetch_versions <entry>` | Prints raw versions for source types `github-release`, `github-tag`, `npm`, `go`, `node`, `k8s`, `mcr`, and `ghcr`. Fails with a message on stderr, including for an unknown type. |
  | `url_sha256 <url>` | Downloads to a temp file in `$WORK` and prints its sha256. Fails with no output if the download fails. |
  | `url_exists <url>` | One-byte `curl -r 0-0` GET. |
  | `render_url <template> <version> [arch]` | Fills in `{version}` and `{arch}`. |
  | `verify_candidate <entry> <version>` | Prints checksum lines, or nothing for entries without checksums. Fails if any download is missing. |
  | `plan_one <index> [verify]` | Prints candidate rows. With `verify`, writes `$WORK/sums/<index>-<version>` and drops unverifiable candidates with the reason on stderr. Fails on a failed lookup or on a lookup with no usable versions. |
  | `lookup_all <mode> <dir> <index...>` | Runs `plan_one` in parallel and writes `<dir>/<index>.rows` and `<dir>/<index>.err`. Held entries are skipped. |
  | `entries_of_kind <kind...>` | Prints matching indexes. |

- Produces (`test.sh` stubs, defined after `update.sh` is sourced so they replace the real functions):
  - The associative arrays `STUB_VERSIONS` (entry name to space-separated versions) and `STUB_URLS` (URL to sha256).
  - Stub `fetch_versions`, `url_sha256`, and `url_exists`. A missing key fails like a 404, and each lookup is logged to `$WORK/fetch-calls`.
  - Tests that need a real function re-source `update.sh` inside their own subshell.

- [ ] **Step 1: Write the stubs and failing tests**

Insert this above `run_tests "$@"` in `scripts/update/test.sh`, with one blank line on each side:

```bash
# Stubs. Tests fill STUB_VERSIONS (entry name -> space-separated versions) and STUB_URLS
# (URL -> sha256). A name or URL that is missing fails the way a 404 would.
declare -A STUB_VERSIONS=() STUB_URLS=()
fetch_versions() {
  local name
  name=$(field "$1" .name)
  echo "$name" >>"$WORK/fetch-calls"
  if [[ -z ${STUB_VERSIONS[$name]+set} ]]; then
    echo "HTTP 404: Not Found" >&2
    return 1
  fi
  printf '%s\n' ${STUB_VERSIONS[$name]}
}
url_sha256() {
  if [[ -z ${STUB_URLS[$1]+set} ]]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    return 1
  fi
  echo "${STUB_URLS[$1]}"
}
url_exists() { [[ -n ${STUB_URLS[$1]+set} ]]; }

# ---------------------------------------------------------------------------------------------
# Sources and verification

test_verify_per_arch_downloads() {
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  check "sums" "amd64 $SHA_1"$'\n'"arm64 $SHA_2" "$(verify_candidate "$(entry omp)" 18.3.0)"
}

test_verify_single_download() {
  STUB_URLS["https://example.test/composer/2.10.4/composer.phar"]=$SHA_3
  check "sums" "- $SHA_3" "$(verify_candidate "$(entry Composer)" 2.10.4)"
}

test_verify_fails_on_missing_arch_download() {
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  check "message" "cannot download https://example.test/omp/v18.3.0/omp-linux-arm64" \
    "$(verify_candidate "$(entry omp)" 18.3.0 2>&1 >/dev/null | tail -n1)"
  check_status "status" 1 verify_candidate "$(entry omp)" 18.3.0
}

test_verify_existence_only() {
  STUB_URLS["https://example.test/awscli-exe-linux-x86_64-2.33.0.zip"]=x
  STUB_URLS["https://example.test/awscli-exe-linux-aarch64-2.33.0.zip"]=x
  check "no sums" "" "$(verify_candidate "$(entry "AWS CLI")" 2.33.0)"
  check_status "both exist" 0 verify_candidate "$(entry "AWS CLI")" 2.33.0
  check_status "one missing" 1 verify_candidate "$(entry "AWS CLI")" 2.34.0
}

test_plan_one_saves_sums_and_drops_unverifiable_candidates() {
  local i
  i=$(index_of omp)
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0 v19.0.0"
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  check "rows" "minor 18.3.0" "$(plan_one "$i" verify 2>/dev/null)"
  check "reason" "19.0.0 skipped: cannot download https://example.test/omp/v19.0.0/omp-linux-x64" \
    "$(plan_one "$i" verify 2>&1 >/dev/null)"
  check "sums" "amd64 $SHA_1"$'\n'"arm64 $SHA_2" "$(cat "$WORK/sums/$i-18.3.0")"
}

test_lookup_with_no_usable_versions_is_an_error() {
  local i
  i=$(index_of omp)
  STUB_VERSIONS[omp]="latest nightly v19.0.0-rc.1"
  lookup_all "" "$WORK/plan" "$i"
  check "error" "lookup found no versions" "$(cat "$WORK/plan/$i.err")"
}

test_url_sha256_hashes_the_download_and_fails_on_error() {
  unset -f url_sha256
  source "$HERE/update.sh"
  curl() {
    local out
    while (($#)); do
      if [[ $1 == -o ]]; then out=$2; fi
      shift
    done
    [[ -n ${STUB_CURL_FAIL:-} ]] && return 22
    printf 'hello\n' >"$out"
  }
  check "sha" "$(printf 'hello\n' | sha256sum | cut -d' ' -f1)" "$(url_sha256 https://example.test/f)"
  STUB_CURL_FAIL=1
  check "no output on failure" "" "$(url_sha256 https://example.test/f)"
  check_status "status on failure" 1 url_sha256 https://example.test/f
  check "no temp files left" "" "$(ls "$WORK" | grep download)"
}

test_lookup_all_records_failures_and_skips_held() {
  local node dotnet vale
  node=$(index_of Node.js) dotnet=$(index_of ".NET SDK (extra)") vale=$(index_of Vale)
  STUB_VERSIONS[Node.js]="v24.15.0 v24.16.0"
  lookup_all "" "$WORK/plan" "$node" "$dotnet" "$vale"
  check "node rows" "minor 24.16" "$(cat "$WORK/plan/$node.rows")"
  check "vale error" "lookup failed: HTTP 404: Not Found" "$(cat "$WORK/plan/$vale.err")"
  check "held not looked up" "" "$(grep -x ".NET SDK (extra)" "$WORK/fetch-calls")"
}

# The real fetch_versions against canned API responses. gh, curl, and npm are stubbed to print
# what the service would return; the jq filters in fetch_versions do the rest.
test_fetch_versions_parses_each_source() {
  source_of() { printf '{"name":"x","source":%s}' "$1"; }
  unset -f fetch_versions
  source "$HERE/update.sh"   # restore the real fetch_versions over the stub
  gh() {
    local jq_filter="" a
    for a in "$@"; do
      if [[ ${prev:-} == --jq ]]; then jq_filter=$a; fi
      prev=$a
    done
    case "$*" in
      *releases*) jq -r "$jq_filter" <<<'[{"tag_name":"v2.0.0","draft":false,"prerelease":false},
        {"tag_name":"v2.1.0-rc1","draft":false,"prerelease":true},
        {"tag_name":"v2.1.0","draft":true,"prerelease":false},
        {"tag_name":"v1.9.9","draft":false,"prerelease":false}]' ;;
      *matching-refs*) jq -r "$jq_filter" <<<'[{"ref":"refs/tags/2.32.9"},{"ref":"refs/tags/2.33.0"}]' ;;
    esac
  }
  npm() { echo '["1.0.0","1.1.0"]'; }
  curl() {
    case "$*" in
      *go.dev*) echo '[{"version":"go1.26.1","stable":true},{"version":"go1.27rc1","stable":false}]' ;;
      *nodejs.org*) echo '[{"version":"v25.1.0","lts":false},{"version":"v24.16.0","lts":"Krypton"}]' ;;
      *dl.k8s.io*) printf 'v1.35.2' ;;
      *mcr.microsoft.com*) echo '{"tags":["2.0.5-10.0-noble","2.0.6-10.0-noble","2-10.0-noble","2.0.6-9.0-noble","dev-10.0-noble"]}' ;;
      *ghcr.io/token*) echo '{"token":"t"}' ;;
      *ghcr.io/v2*) echo '{"tags":["1","1.0","1.0.6","latest"]}' ;;
    esac
  }
  check "github-release" $'v2.0.0\nv1.9.9' "$(fetch_versions "$(source_of '{"type":"github-release","repo":"o/r"}')")"
  check "github-tag" $'2.32.9\n2.33.0' "$(fetch_versions "$(source_of '{"type":"github-tag","repo":"o/r","prefix":"2."}')")"
  check "npm" $'1.0.0\n1.1.0' "$(fetch_versions "$(source_of '{"type":"npm","package":"p"}')")"
  check "go" "1.26.1" "$(fetch_versions "$(source_of '{"type":"go"}')")"
  check "node" "v24.16.0" "$(fetch_versions "$(source_of '{"type":"node"}')")"
  check "k8s" "v1.35.2" "$(fetch_versions "$(source_of '{"type":"k8s"}')")"
  check "mcr" $'2.0.5\n2.0.6\n2\ndev' \
    "$(fetch_versions "$(source_of '{"type":"mcr","image":"devcontainers/dotnet","suffix":"-10.0-noble"}')")"
  check "mcr after filter" $'2.0.5\n2.0.6' \
    "$(fetch_versions "$(source_of '{"type":"mcr","image":"devcontainers/dotnet","suffix":"-10.0-noble"}')" | ver_filter 3)"
  check "ghcr" $'1\n1.0\n1.0.6\nlatest' "$(fetch_versions "$(source_of '{"type":"ghcr","image":"o/f"}')")"
  check_status "unknown type" 1 fetch_versions "$(source_of '{"type":"svn"}')"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `task update:test`

Expected: FAIL with 29 `ok` and 9 `FAIL` lines. Examples: `unknown type (exit status)` expected `1` and got `127`, and `lookup_all: command not found`.

- [ ] **Step 3: Write the sources, verification, and planning section**

Append this to the end of `scripts/update/update.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `task update:test`

Expected: 38 `ok` lines and no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add scripts/update/test.sh scripts/update/update.sh
git commit -m "feat(update): look up, verify, and plan version candidates"
```

---

### Task 5: Terminal UI and the pins and Features steps

**Files:**
- Modify: `scripts/update/test.sh` (insert stubs and tests)
- Modify: `scripts/update/update.sh` (append a section)

**Interfaces:**
- Consumes (Tasks 2 to 4): `apply_item`, `lookup_all`, `entries_of_kind`, `current_value`, `field`, the summary arrays, and `REBUILD`.
- Produces (`update.sh`):

  | Function | Behavior |
  | --- | --- |
  | `resolve_choices` | Reads `<index>:<kind>` tags on stdin and prints `<index> <kind>` once per index. Major wins when both rows are chosen. |
  | `dialog_checklist <title> <tag> <label> <on\|off>...` | Prints the chosen tags. Fails on Cancel or Esc. |
  | `dialog_yesno <title> <question>` | Fails on No, Cancel, or Esc. |
  | `dialog_notice <title> <message>` | Shows a message. |
  | `clear_screen` | Clears the terminal. |
  | `refresh_lock` | Runs `npx --yes @devcontainers/cli upgrade --workspace-folder .` from the repo root. |
  | `run_command <cmd>` | Runs the command from the repo root. |
  | `sync_repos` | Runs `scripts/sync-repos.sh --pull`. |
  | `run_edit_step pins\|features` | Runs one full step and appends to `UPDATED`, `SKIPPED`, `FAILED`, and `HELD`. Sets `REBUILD=true` if a file changed. |

- Produces (`test.sh` stubs):

  | Variable | Effect |
  | --- | --- |
  | `STUB_CHOICES` | Space-separated tags to choose. Without it, every row that starts `on` is chosen. |
  | `STUB_CANCEL=1` | Presses Cancel. |
  | `STUB_LOCK_STATUS` and `STUB_LOCK_WRITE` | The lock refresh's exit status, and text it writes to `$LOCK_JSON`. |
  | `STUB_SYNC_STATUS` | The repo sync's exit status. |

  Notices are appended to `$WORK/notices`, lock refreshes to `$WORK/lock-calls`, and repo syncs to `$WORK/sync-calls`.

- [ ] **Step 1: Write the stubs and failing tests**

Insert this above `run_tests "$@"` in `scripts/update/test.sh`, with one blank line on each side:

```bash
# dialog stubs: STUB_CHOICES (space-separated tags) overrides the default of choosing every row
# that starts "on"; STUB_CANCEL=1 presses Cancel. Notices are appended to $WORK/notices.
dialog_checklist() {
  shift
  if [[ -n ${STUB_CANCEL:-} ]]; then
    return 1
  fi
  if [[ -n ${STUB_CHOICES+set} ]]; then
    printf '%s\n' $STUB_CHOICES
    return 0
  fi
  while (($#)); do
    if [[ $3 == on ]]; then
      echo "$1"
    fi
    shift 3
  done
}
dialog_yesno() { [[ -z ${STUB_CANCEL:-} ]]; }
dialog_notice() { printf '%s\n%s\n' "$1" "$2" >>"$WORK/notices"; }
clear_screen() { :; }
refresh_lock() {
  echo refreshed >>"$WORK/lock-calls"
  if [[ -n ${STUB_LOCK_WRITE:-} ]]; then
    echo "$STUB_LOCK_WRITE" >"$LOCK_JSON"
  fi
  return "${STUB_LOCK_STATUS:-0}"
}
sync_repos() {
  echo pulled >>"$WORK/sync-calls"
  return "${STUB_SYNC_STATUS:-0}"
}

# ---------------------------------------------------------------------------------------------
# Pins and features steps

test_pins_step_applies_preselected_rows() {
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  STUB_VERSIONS["AWS CLI"]="2.32.9"
  STUB_VERSIONS[Composer]="2.10.3"
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0 v19.0.0"
  STUB_VERSIONS[Vale]="v3.12.0"
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-arm64"]=$SHA_2
  run_edit_step pins >/dev/null
  check "updated" $'base image  2.0.5 -> 2.0.6\nomp  18.2.7 -> 18.3.0' "$(printf '%s\n' "${UPDATED[@]}")"
  check "omp version" 18.3.0 "$(current_value "$(entry omp)")"
  check "omp arm64 sum" "$SHA_2" "$(anchor_value "$(anchor "$(entry omp)" sha256:arm64)")"
  check "rebuild" true "$REBUILD"
  check "failed" "" "${FAILED[*]}"
}

test_pins_step_major_wins_when_both_rows_chosen() {
  local i
  i=$(index_of omp)
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0 v19.0.0"
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v18.3.0/omp-linux-arm64"]=$SHA_2
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-x64"]=$SHA_1
  STUB_URLS["https://example.test/omp/v19.0.0/omp-linux-arm64"]=$SHA_2
  STUB_CHOICES="$i:minor $i:major"
  run_edit_step pins >/dev/null
  check "omp version" 19.0.0 "$(current_value "$(entry omp)")"
}

test_pins_step_reports_lookup_and_download_problems() {
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0"
  run_edit_step pins >/dev/null
  check "notice" "Pinned tools (Dockerfile): not offered" "$(head -n1 "$WORK/notices")"
  check "vale skipped" "Vale: lookup failed: HTTP 404: Not Found" "$(printf '%s\n' "${SKIPPED[@]}" | grep '^Vale')"
  check "omp skipped" "omp: 18.3.0 skipped: cannot download https://example.test/omp/v18.3.0/omp-linux-x64" \
    "$(printf '%s\n' "${SKIPPED[@]}" | grep '^omp')"
  check "nothing changed" "" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
}

test_pins_step_survives_esc_on_the_notice() {
  dialog_notice() { return 255; }
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  run_edit_step pins >/dev/null
  check "still applied" "base image  2.0.5 -> 2.0.6" "${UPDATED[*]}"
}

test_pins_step_cancel_changes_nothing() {
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  STUB_CANCEL=1
  run_edit_step pins >/dev/null
  check "nothing changed" "" "$(changes "$WORK/Dockerfile.orig" "$DOCKERFILE")"
  check "skipped" "Pinned tools (Dockerfile): cancelled" "${SKIPPED[-1]}"
  check "updated" "" "${UPDATED[*]}"
}

test_pins_step_records_unchosen_rows() {
  STUB_VERSIONS["base image"]="2.0.5 2.0.6"
  STUB_CHOICES=""
  run_edit_step pins >/dev/null
  check "skipped" "base image: not chosen" "$(printf '%s\n' "${SKIPPED[@]}" | grep '^base image')"
}

test_features_step_refreshes_lock_once_and_reports_held() {
  STUB_VERSIONS[Node.js]="v24.15.0 v24.16.0"
  STUB_VERSIONS[TFLint]="v0.62.0 v0.62.1"
  run_edit_step features >/dev/null
  check "updated" $'TFLint  0.62.0 -> 0.62.1\nNode.js  24.15 -> 24.16' "$(printf '%s\n' "${UPDATED[@]}")"
  check "lock refreshed once" refreshed "$(cat "$WORK/lock-calls")"
  check "held" ".NET SDK (extra) 8.0: kept on 8.0 on purpose" "${HELD[*]}"
}

test_features_step_restores_both_files_when_lock_refresh_fails() {
  # The restore goes back to how the files were when the run started, uncommitted edits
  # included, not to what git has.
  sed -i 's|^  "features": {|  // a local edit that is not committed\n&|' "$DEVCONTAINER_JSON"
  cp "$DEVCONTAINER_JSON" "$WORK/devcontainer.json.start"
  STUB_VERSIONS[Node.js]="v24.15.0 v24.16.0"
  STUB_LOCK_STATUS=1
  STUB_LOCK_WRITE='{"features": {"half-written": true}}'
  run_edit_step features >/dev/null
  check "devcontainer.json restored" "" "$(changes "$WORK/devcontainer.json.start" "$DEVCONTAINER_JSON")"
  check "local edit kept" "  // a local edit that is not committed" "$(grep 'not committed' "$DEVCONTAINER_JSON")"
  check "lock restored" "" "$(changes "$HERE/testdata/devcontainer-lock.json" "$LOCK_JSON")"
  check "failed" "Node.js: lock file refresh failed, devcontainer.json restored" "${FAILED[*]}"
  check "updated" "" "${UPDATED[*]}"
  check "rebuild" false "$REBUILD"
}

test_features_step_lock_row_alone() {
  STUB_CHOICES="lock"
  run_edit_step features >/dev/null
  check "lock refreshed" refreshed "$(cat "$WORK/lock-calls")"
  check "updated" "Feature lock file refreshed" "${UPDATED[*]}"
  check "nothing changed" "" "$(changes "$WORK/devcontainer.json.orig" "$DEVCONTAINER_JSON")"
}

test_features_step_lock_row_alone_reports_a_failed_refresh() {
  STUB_CHOICES="lock"
  STUB_LOCK_STATUS=1
  run_edit_step features >/dev/null
  check "failed" "Feature lock file: refresh failed" "${FAILED[*]}"
  check "updated" "" "${UPDATED[*]}"
}

test_features_step_without_changes_skips_lock() {
  run_edit_step features >/dev/null
  check "no refresh" "" "$(cat "$WORK/lock-calls" 2>/dev/null)"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `task update:test`

Expected: FAIL with 38 `ok` and 11 `FAIL` lines. The failures print `run_edit_step: command not found`.

- [ ] **Step 3: Write the UI and steps section**

Append this to the end of `scripts/update/update.sh`:

```bash
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
  local step=$1 title i kind v e old row label tags err changed=false
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
    if err=$(apply_item "$e" "$v" "$(cat "$WORK/sums/$i-$v" 2>/dev/null)" 2>&1); then
      applied+=("$(field "$e" .name)  $old -> $v")
      changed=true
    else
      FAILED+=("$(field "$e" .name): $err")
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `task update:test`

Expected: 49 `ok` lines and no `FAIL`.

- [ ] **Step 5: Commit**

```bash
git add scripts/update/test.sh scripts/update/update.sh
git commit -m "feat(update): add checklist UI and the pins and features steps"
```

---

### Task 6: Tools, repos, check, entry point, tasks, and docs

**Files:**
- Modify: `scripts/update/test.sh` (insert tests)
- Modify: `scripts/update/update.sh` (append the last section)
- Modify: `Taskfile.yml` (replace with the full version)
- Modify: `README.md` (add a table of contents line and a section)
- Modify: `AGENTS.md:109`

**Interfaces:**
- Consumes (Tasks 1 to 5): everything above.
- Produces (`update.sh`):

  | Function | Behavior |
  | --- | --- |
  | `run_tools` | Checklist of `command` entries, then runs the chosen ones. |
  | `run_repos` | Asks for confirmation, then runs `sync_repos`. |
  | `run_check` | Prints the report table. Fails if a lookup failed. |
  | `choose_steps` | The top-level checklist. |
  | `print_list` | Prints one titled list for the summary. |
  | `print_summary` | Prints the summary lists, `git diff --stat`, and the rebuild reminder. |
  | `on_exit` | EXIT trap that removes `$WORK`. |
  | `main <step>` | Rejects unknown steps with exit 2, and interactive steps without a terminal with exit 1. Sets up `WORK` and the traps, then calls `run_steps`. |
  | `run_steps <step>` | Runs the step and the summary. Fails if any chosen item failed. |

  When the file is executed, not sourced, it runs `main "$@"`.
- Produces (Taskfile): `update`, `update:pins`, `update:features`, `update:tools`, `update:repos`, `update:check`, and `update:test`.

- [ ] **Step 1: Write the failing tests**

Insert this above `run_tests "$@"` in `scripts/update/test.sh`, with one blank line on each side:

```bash
# ---------------------------------------------------------------------------------------------
# Tools, repos, check, and main

test_tools_step_runs_chosen_commands() {
  local out
  out=$(run_tools; declare -p UPDATED FAILED)
  check "output" "tool-a-ran" "$(grep -x tool-a-ran <<<"$out")"
  eval "$(grep '^declare' <<<"$out")"
  check "updated" "Tool A (in place)" "${UPDATED[*]}"
  check "failed" "Tool B: 'exit 3' failed" "${FAILED[*]}"
}

test_tools_step_runs_only_chosen() {
  STUB_CHOICES=$(index_of "Tool A")
  run_tools >/dev/null
  check "updated" "Tool A (in place)" "${UPDATED[*]}"
  check "failed" "" "${FAILED[*]}"
}

test_repos_step() {
  run_repos >/dev/null
  check "pulled" pulled "$(cat "$WORK/sync-calls")"
  check "updated" "Crucible repos (git pull)" "${UPDATED[*]}"
}

test_repos_step_cancel() {
  STUB_CANCEL=1
  run_repos >/dev/null
  check "not pulled" "" "$(cat "$WORK/sync-calls" 2>/dev/null)"
  check "skipped" "Crucible repos: cancelled" "${SKIPPED[*]}"
}

test_check_reports_every_status() {
  local out
  STUB_VERSIONS["base image"]="2.0.5"
  STUB_VERSIONS[omp]="v18.2.7 v18.3.0 v19.0.0"
  STUB_VERSIONS[Node.js]="v24.15.0 v24.16.0"
  out=$(run_check 2>/dev/null) || true
  check_status "exit status with a failed lookup" 1 run_check
  check "base image" "base image                     2.0.5        2.0.5        2.0.5        up to date" \
    "$(grep '^base image' <<<"$out")"
  check "omp" "omp                            18.2.7       18.3.0       19.0.0       MAJOR" "$(grep '^omp' <<<"$out")"
  check "node" "Node.js                        24.15        24.16        24.16        update" "$(grep '^Node.js' <<<"$out")"
  check "dotnet" ".NET SDK (extra)               8.0          8.0          8.0          held: kept on 8.0 on purpose" \
    "$(grep '^.NET' <<<"$out")"
  check "vale" "Vale                           3.12.0       -            -            error: lookup failed: HTTP 404: Not Found" \
    "$(grep '^Vale' <<<"$out")"
  check "no commands" "" "$(grep '^Tool' <<<"$out")"
  check "no downloads" "" "$(ls "$WORK/sums")"
}

test_all_runs_only_the_chosen_steps() {
  STUB_CHOICES=repos
  run_steps all >/dev/null
  check "pulled" pulled "$(cat "$WORK/sync-calls")"
  check "nothing looked up" "" "$(cat "$WORK/fetch-calls" 2>/dev/null)"
}

test_all_cancel_runs_nothing() {
  STUB_CANCEL=1
  check "output" "Nothing chosen." "$(run_steps all)"
}

test_run_steps_fails_when_a_chosen_item_failed() {
  check_status "clean pull" 0 run_steps repos
  STUB_SYNC_STATUS=1
  check_status "failed pull" 1 run_steps repos
}

test_main_requires_a_terminal() {
  local out status
  out=$(bash "$UPDATE_DIR/update.sh" pins </dev/null 2>&1) && status=0 || status=$?
  check "status" 1 "$status"
  check "message" "update.sh pins needs an interactive terminal. For a report with no prompts, run: task update:check" "$out"
}

test_main_rejects_unknown_step() {
  check_status "unknown step" 2 bash "$UPDATE_DIR/update.sh" everything
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `task update:test`

Expected: FAIL with 49 `ok` and 10 `FAIL` lines. Examples: `run_steps: command not found`, and `output` expected `Nothing chosen.` and got an empty string.

- [ ] **Step 3: Write the last section**

Append this to the end of `scripts/update/update.sh`:

```bash
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
```

- [ ] **Step 4: Replace `Taskfile.yml` with the full version**

```yaml
# Copyright 2026 Carnegie Mellon University. All Rights Reserved.
# Released under a MIT (SEI)-style license. See LICENSE.md in the project root for license information.
#
# Dev container maintenance tasks. Run `task --list` to see them. The update tasks are described
# in the README under "Updating the Dev Container".

version: '3'

silent: true

tasks:
  update:
    desc: Choose what to update, then update it (pins, Features, container tools, repos)
    interactive: true
    preconditions: &lookup-preconditions
      - sh: command -v dialog >/dev/null
        msg: dialog is missing. Rebuild the dev container, or run `sudo apt-get install -y dialog`.
      - sh: command -v jq >/dev/null && command -v curl >/dev/null
        msg: jq and curl are required. Rebuild the dev container.
      - sh: gh auth status >/dev/null 2>&1
        msg: Version lookups use the GitHub API. Run `gh auth login` first.
    cmds:
      - bash scripts/update/update.sh all

  update:pins:
    desc: Update the version pins and checksums in .devcontainer/Dockerfile
    interactive: true
    preconditions: *lookup-preconditions
    cmds:
      - bash scripts/update/update.sh pins

  update:features:
    desc: Update Feature versions in .devcontainer/devcontainer.json and refresh the lock file
    interactive: true
    preconditions: *lookup-preconditions
    cmds:
      - bash scripts/update/update.sh features

  update:tools:
    desc: Update tools that update themselves in the running container (Claude Code, Codex, ...)
    interactive: true
    preconditions:
      - sh: command -v dialog >/dev/null
        msg: dialog is missing. Rebuild the dev container, or run `sudo apt-get install -y dialog`.
      - sh: command -v jq >/dev/null
        msg: jq is required. Rebuild the dev container.
    cmds:
      - bash scripts/update/update.sh tools

  update:repos:
    desc: Pull every Crucible repository (scripts/sync-repos.sh --pull)
    interactive: true
    preconditions:
      - sh: command -v dialog >/dev/null
        msg: dialog is missing. Rebuild the dev container, or run `sudo apt-get install -y dialog`.
      - sh: command -v jq >/dev/null
        msg: jq is required. Rebuild the dev container.
    cmds:
      - bash scripts/update/update.sh repos

  update:check:
    desc: Report current and newest versions for every pin, with no prompts and no edits
    preconditions:
      - sh: command -v jq >/dev/null && command -v curl >/dev/null
        msg: jq and curl are required. Rebuild the dev container.
      - sh: gh auth status >/dev/null 2>&1
        msg: Version lookups use the GitHub API. Run `gh auth login` first.
    cmds:
      - bash scripts/update/update.sh check

  update:test:
    desc: Run the offline tests for scripts/update
    cmds:
      - bash scripts/update/test.sh {{.CLI_ARGS}}
```

- [ ] **Step 5: Run the tests and the entry points to verify they pass**

Run: `task update:test && bash -n scripts/update/update.sh && bash -n scripts/update/test.sh`

Expected: 59 `ok` lines and no `FAIL`.

Run: `task --list`

Expected: seven tasks: `update`, `update:check`, `update:features`, `update:pins`, `update:repos`, `update:test`, and `update:tools`.

Run: `bash scripts/update/update.sh pins </dev/null; echo "exit=$?"; bash scripts/update/update.sh bogus; echo "exit=$?"`

Expected:

```text
update.sh pins needs an interactive terminal. For a report with no prompts, run: task update:check
exit=1
usage: scripts/update/update.sh all|pins|features|tools|repos|check
exit=2
```

- [ ] **Step 6: Add the README section**

First run `markdownlint-cli2 README.md 2>&1 | grep 'README.md:' | grep -vc MD013` and note the count. README already has many MD013 (line length) warnings, which is why they are left out.

Make two edits in `README.md`:

1. In the table of contents, add a line directly after `  - [Default Credentials](#default-credentials)`:

   ```markdown
     - [Updating the Dev Container](#updating-the-dev-container)
   ```

2. Insert the section directly above the `## Claude Code` heading, after the end of the "Persistent Caches" section (its closing code fence). Leave one blank line on each side:

```markdown
### Updating the Dev Container

`task update` brings the dev container's tools up to date. It shows checklists in the terminal (Space toggles an item, Enter applies, Esc skips the step) and edits files in place. It never commits, pushes, or rebuilds anything: review the result with `git diff`, then open a pull request so [Devcontainer CI](#devcontainer-ci) builds it for amd64 and arm64.

| Task | What it updates |
| --- | --- |
| `task update` | Asks which of the steps below to run, then runs them in this order. |
| `task update:pins` | Version pins in `.devcontainer/Dockerfile` (base image, AWS CLI, Composer, Vale, omp, herdr, t3code, kubefwd), with their amd64 and arm64 checksums. |
| `task update:features` | Feature versions and Feature `version` options in `.devcontainer/devcontainer.json`, then refreshes `.devcontainer/devcontainer-lock.json`. |
| `task update:tools` | Tools that update themselves inside the running container: Claude Code, Codex, Angular CLI, dotnet-ef, gh-stack, and moodle-cs. These updates last until the next rebuild. |
| `task update:repos` | Pulls every Crucible repository with `scripts/sync-repos.sh --pull`. |
| `task update:check` | Prints the current and newest version of every pin. No prompts, no edits. |

How versions are chosen:

- Each item offers the newest release in its current major version (checked) and, if there is one, a newer major version (unchecked, marked `MAJOR`). For `0.x` versions a new minor version counts as major.
- A pin keeps its precision. `"version": "24.15"` moves to the newest `24.x` minor version, not to a patch release.
- Every offered version has been checked first. For pins with checksums, both architectures' downloads are fetched and hashed, and those hashes are what get written. Other downloads are checked to exist.
- Items with `"hold": true` in `scripts/update/tools.json` are never offered, and the summary lists them with their reason. The .NET SDK Feature is held on 8.0 because the base image already supplies .NET 10.

Version lookups call the GitHub API through `gh`, so run `gh auth login` first (see [GitHub CLI](#github-cli)). After updating pins or Features, rebuild the dev container to use them.

Every pin the updater manages is listed in `scripts/update/tools.json`. When you add a tool to the Dockerfile or a Feature to `devcontainer.json`, add an entry there too. `task update:test` fails if a Dockerfile `ARG *_VERSION` or a registry Feature has no entry.
```

Run the same `markdownlint-cli2` command again. Expected: the same count as before.

- [ ] **Step 7: Extend the AGENTS.md rule**

`AGENTS.md` line 109, under `## Devcontainer CI`, is the paragraph that starts `**IMPORTANT:** When adding a new tool to the dev container`. Replace the whole line with:

```markdown
**IMPORTANT:** When adding a new tool to the dev container — whether via a new devcontainer Feature, a Dockerfile `RUN`, or a `postcreate.sh` install step — add a matching `check` line to `.devcontainer/ci-verify-tools.sh`. Prefer the shortest version command that doesn't touch the network or a server (e.g. `kubectl version --client=true`, not `kubectl version`). If the tool has a version pin (a Dockerfile `ARG`, a Feature tag, or a Feature `version` option), also add an entry for it to `scripts/update/tools.json` so `task update` can update it, or `"hold": true` with a `reason` if the pin is kept back on purpose. `task update:test` fails when a Dockerfile `ARG *_VERSION` or a registry Feature has no entry.
```

Do not edit `CLAUDE.md`. It is a symlink to `AGENTS.md`.

- [ ] **Step 8: Commit**

If the "Before you start" answer was to leave `README.md` uncommitted, drop `README.md` from this `git add` and tell the developer the section is in their working tree next to their own README changes.

```bash
git add scripts/update/test.sh scripts/update/update.sh Taskfile.yml AGENTS.md README.md
git commit -m "feat(update): add task update with tools, repos, and check steps"
```

---

### Task 7: Live verification against the real upstreams

The offline tests prove the engine. This task proves the real manifest: every source resolves, and every URL template and arch map downloads the same files the Dockerfile installs.

**Files:**
- Modify (only if a check fails): `scripts/update/tools.json`

**Interfaces:**
- Consumes: `task update:check`, plus `load_manifest`, `field`, `current_value`, `anchor`, `anchor_value`, and `verify_candidate` from `update.sh`.
- Produces: a manifest confirmed against the network.

- [ ] **Step 1: Run the report**

Run: `task update:check`

Expected: the header `ITEM  CURRENT  IN MAJOR  NEWEST  STATUS`, then 33 rows: the base image, 7 Dockerfile ARGs, 14 Feature options, and 11 Feature refs. The command entries are left out. `.NET SDK (extra)` shows `held: The base image supplies .NET 10; this Feature adds .NET 8 on purpose.` and no row shows `error:`. The exit status is 0 whether or not updates are available.

If the precondition fails with `Version lookups use the GitHub API. Run gh auth login first.`, or network access is blocked where you are running, ask the developer to run `! task update:check` and use their output.

- [ ] **Step 2: Fix any `error:` rows**

For each row with `error: <message>`, fix that entry in `scripts/update/tools.json`:

| Message | Likely cause | Check |
| --- | --- | --- |
| `lookup failed: HTTP 404...` (GitHub) | The repo was renamed or moved. | `gh api repos/<repo> --jq .full_name` |
| `lookup found no versions` (`github-release`) | The project tags releases differently, or publishes only prereleases. | `gh api repos/<repo>/releases --jq '.[0:5][] \| [.tag_name, .prerelease] \| @tsv'` |
| `lookup found no versions` (`github-tag`) | The `prefix` does not match the tags. | `gh api repos/<repo>/git/matching-refs/tags/<prefix> --jq '.[-5:][].ref'` |
| `lookup failed` (`mcr` or `ghcr`) | The `image` path is wrong. | Compare it with the `FROM` line or the Feature key in the real files. |
| `cannot find its current version` | The anchor does not match the real file. `test_real_manifest_matches_real_files` should already have caught this. | `task update:test -- real` |

After each fix, run `task update:test` (still 59 `ok`) and then `task update:check` again.

- [ ] **Step 3: Check the checksum and URL templates at today's pins**

This runs `verify_candidate` at each Dockerfile ARG's current version and compares the result with the checksums already in the Dockerfile. It downloads each binary once per architecture, about 1 GB in total.

Run from the repo root:

```bash
bash -c '
  set -euo pipefail
  source scripts/update/update.sh
  WORK=$(mktemp -d)
  trap "rm -rf $WORK" EXIT
  load_manifest
  for e in "${ENTRIES[@]}"; do
    if [[ $(field "$e" .kind) != dockerfile-arg ]]; then
      continue
    fi
    name=$(field "$e" .name)
    v=$(current_value "$e")
    if ! sums=$(verify_candidate "$e" "$v"); then
      echo "FAIL  $name $v"
      continue
    fi
    if [[ -z $sums ]]; then
      echo "ok    $name $v: downloads exist"
      continue
    fi
    while read -r arch sum; do
      if [[ $arch == - ]]; then
        a=$(anchor "$e" sha256)
      else
        a=$(anchor "$e" "sha256:$arch")
      fi
      if [[ $(anchor_value "$a") == "$sum" ]]; then
        echo "ok    $name $v $arch: checksum matches the Dockerfile"
      else
        echo "DIFF  $name $v $arch: got $sum"
      fi
    done <<<"$sums"
  done'
```

Expected output:

```text
ok    AWS CLI 2.32.9: downloads exist
ok    Composer 2.10.3 -: checksum matches the Dockerfile
ok    Vale 3.12.0: downloads exist
ok    omp 18.2.7 amd64: checksum matches the Dockerfile
ok    omp 18.2.7 arm64: checksum matches the Dockerfile
ok    herdr 0.9.1 amd64: checksum matches the Dockerfile
ok    herdr 0.9.1 arm64: checksum matches the Dockerfile
ok    t3code 0.0.42 amd64: checksum matches the Dockerfile
ok    t3code 0.0.42 arm64: checksum matches the Dockerfile
ok    kubefwd 1.25.14: downloads exist
```

The versions are whatever the Dockerfile pins at the time.

- `FAIL`: the `url` template or `arch` map is wrong. The line above it names the URL that could not be downloaded. Compare it with the download URL in that tool's `RUN` block in `.devcontainer/Dockerfile`, fix the entry, and rerun.
- `DIFF`: the template downloads a different file than the Dockerfile does. Fix it the same way. Never change a checksum in the Dockerfile to make this pass.

- [ ] **Step 4: Run the tests**

Run: `task update:test`

Expected: 59 `ok` lines and no `FAIL`.

- [ ] **Step 5: Commit any manifest fixes**

Skip this step if `tools.json` did not change.

```bash
git add scripts/update/tools.json
git commit -m "fix(update): correct manifest sources found by the live check"
```

- [ ] **Step 6: Hand off the interactive smoke test**

`dialog` needs a real terminal, so the developer has to run this part. Ask them to:

1. Run `! task update`, choose steps, try Space, Enter, and Esc in the checklists, and read the summary.
2. Review the result with `git diff -- .devcontainer`.

Remind them that `.devcontainer/devcontainer.json` already holds their uncommitted GPT-6/t3 edits. Unwanted updater edits must be undone by hand, not with `git checkout` or `git restore`, which would also discard that work.
