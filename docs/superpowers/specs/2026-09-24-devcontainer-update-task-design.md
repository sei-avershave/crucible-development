# Dev container update task: design

Date: 2026-09-24
Status: approved. Revised while writing the implementation plan: Feature option anchors ignore
the tag, rollback is per item, existence checks use a one-byte GET, and tests use function stubs.

## Goal

Give developers one interactive command that brings everything the dev container installs up to
date: the version pins in `.devcontainer/Dockerfile`, the Feature versions in
`.devcontainer/devcontainer.json`, the tools that update themselves inside a running container,
and the cloned Crucible repositories. Today each of these is bumped by hand, one PR at a time
(for example `0f022a3`, which updated omp and herdr), and each bump means looking up the release,
downloading both architectures to compute checksums, and editing the right lines.

Success means a developer runs `task update`, ticks what they want in checklist menus, and ends up
with a working tree of reviewed-ready edits (versions and checksums both correct for amd64 and
arm64) that CI's dev container build can validate on a PR.

## Constraints

- Task (go-task 3.50.0) is already installed by the `go-task` Feature; `dialog`, `jq`, `curl`,
  `gh`, and `npm` are all present. `gum`, `fzf`, `whiptail`, `yq`, `shellcheck`, `bats`, and
  `shfmt` are not, and this work adds none of them.
- The tool edits files and runs updaters. It never commits, pushes, or rebuilds the container.
  The developer reviews `git diff` and opens a PR; `.github/workflows/devcontainer-ci.yml` builds
  both architectures.
- `devcontainer.json` is JSONC with comments. Edits must leave comments and formatting intact.
- Files are rewritten in place (same inode), matching the pattern that keeps single-file bind
  mounts such as `/etc/codex/config.toml` working.

## Files

| File | Role |
|------|------|
| `Taskfile.yml` (repo root, new) | Entry points only. Each task calls `scripts/update/update.sh`. |
| `scripts/update/tools.json` (new) | Manifest: every updatable item, where its latest version comes from, and how to edit it. |
| `scripts/update/update.sh` (new) | Engine: lookups, verification, checklists, edits, summary. Its functions can be sourced for tests (`main` runs only when executed directly). |
| `scripts/update/test.sh` (new) | Offline tests for the engine. |
| `scripts/update/testdata/` (new) | Small fixture Dockerfile, `devcontainer.json`, lock file, and manifest for the tests. |
| `README.md`, `AGENTS.md` | Documentation (see [Docs](#docs)). |

## Tasks

| Task | What it does |
|------|--------------|
| `task update` | Category checklist (Pinned tools, Features, Container tools, Crucible repos), then runs each chosen category in that order. |
| `task update:pins` | Dockerfile `ARG` pins, their checksums, and the base image tag. |
| `task update:features` | Feature options and Feature refs in `devcontainer.json`, then refreshes `devcontainer-lock.json`. |
| `task update:tools` | Runs in-place updaters inside the running container. |
| `task update:repos` | Confirms, then runs `scripts/sync-repos.sh --pull`. |
| `task update:check` | Report only: prints current vs latest for every manifest item. No prompts, no edits. |
| `task update:test` | Runs `scripts/update/test.sh`. `task update:test -- <text>` runs only tests whose names contain `<text>`. |

Every interactive task sets `interactive: true` so Task hands the terminal straight to `dialog`
and requires `dialog`. Tasks that look up versions (`update`, `update:pins`, `update:features`,
`update:check`) also require `jq`, `curl`, and a passing `gh auth status`. These are Task
`preconditions`, and each one's message says what to install or run.

## Flow for pins and features

1. Load the manifest entries for the category.
2. Look up each entry's versions (see [Sources](#sources)). Lookups run in parallel.
3. Compute candidates (see [Version rules](#version-rules)) and drop items that are up to date or
   held.
4. Verify each candidate (see [Verification](#verification)).
5. If any lookup or verification failed, show a notice listing those items and the reason
   (`vale: GitHub API 403 rate limit`). They are left out of the checklist; the rest continue.
   Closing the notice with Esc does not stop the run. A lookup that returns no usable versions
   (a wrong repo or tag prefix, or only prereleases) is a failure, not "up to date".
6. Show a `dialog --checklist`. Each row reads `name  current -> candidate`, with `MAJOR` appended
   to major bumps. Non-major candidates start checked; major candidates start unchecked.
7. Apply the chosen edits (see [Applying edits](#applying-edits)).
8. For features, refresh the lock file if any Feature line changed.
9. Print the summary.

`update:tools` shows a checklist of its command entries (all checked), runs the chosen commands
one at a time with their output visible, and records pass or fail for each.

`update:repos` shows a yes/no confirmation, then runs `scripts/sync-repos.sh --pull` for all
repositories. There is no per-repo selection.

## Manifest

`scripts/update/tools.json` is a JSON array. Every entry has a `name`, a `kind`, and, except for
`command` and held entries, a `source`. Optional fields on every kind: `hold` (boolean) with
`reason` (string), for pins kept back on purpose.

### Kinds

**`dockerfile-arg`**: an `ARG NAME=value` line in the Dockerfile. Quoted values
(`ARG AWS_CLI_VERSION="2.32.9"`) keep their quotes. Optional `sha256` object:

- `var`: the name of a shell variable set in per-arch `case` lines of the `RUN` block that follows
  the `ARG` (omp, herdr, t3code), or
- `arg`: the name of a separate `ARG` holding a single checksum (composer).
- `url`: download URL template with `{version}` and, for `var`, `{arch}`.
- `arch`: map from Docker arch (`amd64`, `arm64`) to the value substituted for `{arch}`. Required
  with `var`.

Entries without `sha256` may give `url` and `arch` at the top level so verification can check that
both downloads exist.

**`base-image`**: the `FROM` line. The tag has a version part and a fixed suffix
(`2.0.5` and `-10.0-noble`); only the version part changes.

**`feature-option`**: an option inside a Feature's block in `devcontainer.json`. Fields: `feature`
(the Feature key without its tag, for example `ghcr.io/devcontainers/features/node` or
`./features/aspire`) and `option`. The key matches with or without a tag, so an option entry
keeps working after its Feature ref is bumped.

**`feature-ref`**: the version tag at the end of a Feature key (`common-utils:2.5`). Field:
`feature` (the key without the tag, for example `ghcr.io/devcontainers/features/common-utils`).

**`command`**: an in-place updater for `update:tools`. Field: `run` (a shell command). No source,
no version lookup.

Example:

```json
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
}
```

### Sources

| `type` | Fields | Lookup |
|--------|--------|--------|
| `github-release` | `repo` | `gh api` on the releases list; drops drafts and prereleases. |
| `github-tag` | `repo`, optional `prefix` | `gh api repos/{repo}/git/matching-refs/tags/{prefix}`. Used where releases are not published (AWS CLI v2, Docker). |
| `npm` | `package` | `npm view {package} versions --json`. |
| `go` | none | `https://go.dev/dl/?mode=json&include=all`, stable only. |
| `node` | none | `https://nodejs.org/dist/index.json`, LTS lines only. |
| `k8s` | none | `https://dl.k8s.io/release/stable.txt`. Enough for the two-component kubectl pin. |
| `mcr` | `image`, `suffix` | `https://mcr.microsoft.com/v2/{image}/tags/list`, filtered to `^X.Y.Z{suffix}$`. |
| `ghcr` | `image` | ghcr.io registry tags list with an anonymous pull token. |

For every source a leading `v` is stripped, and only versions made of dot-separated integers are
kept, which drops `-rc`, `-beta`, and similar suffixes.

### Inventory

The initial manifest covers every pin that exists today.

| Name | Kind | Where | Source | Notes |
|------|------|-------|--------|-------|
| dev container base image | base-image | `FROM` | mcr `devcontainers/dotnet`, suffix `-10.0-noble` | |
| AWS CLI | dockerfile-arg | `AWS_CLI_VERSION` | github-tag `aws/aws-cli`, prefix `2.` | Existence check on both arch zip URLs. |
| Composer | dockerfile-arg | `COMPOSER_VERSION` | github-release `composer/composer` | `sha256.arg` = `COMPOSER_SHA256`; no arch. |
| Vale | dockerfile-arg | `VALE_VERSION` | github-release `errata-ai/vale` | Existence check. |
| omp | dockerfile-arg | `OMP_VERSION` | github-release `can1357/oh-my-pi` | Per-arch `OMP_SHA256`. |
| herdr | dockerfile-arg | `HERDR_VERSION` | github-release `herdrdev/herdr` | Per-arch `HERDR_SHA256`. |
| t3code | dockerfile-arg | `T3CODE_VERSION` | github-release `pingdotgg/t3code` | Per-arch `T3_SHA256`. |
| kubefwd | dockerfile-arg | `KUBEFWD_VERSION` | github-release `txn2/kubefwd` | Existence check. |
| markdownlint-cli2 | feature-option | markdownlint-cli2 `version` | npm `markdownlint-cli2` | |
| GitHub CLI | feature-option | github-cli `version` | github-release `cli/cli` | |
| .NET SDK (extra) | feature-option | dotnet `version` | none | `hold`: the base image supplies .NET 10; the Feature adds 8.0 on purpose. |
| Terraform | feature-option | terraform `version` | github-release `hashicorp/terraform` | |
| TFLint | feature-option | terraform `tflint` | github-release `terraform-linters/tflint` | |
| Terragrunt | feature-option | terraform `terragrunt` | github-release `gruntwork-io/terragrunt` | |
| Go | feature-option | go `version` | go | |
| Task | feature-option | go-task `version` | github-release `go-task/task` | |
| Docker | feature-option | docker-in-docker `version` | github-tag `docker/cli`, prefix `v` | |
| kubectl | feature-option | kubectl-helm-minikube `version` | k8s | |
| Helm | feature-option | kubectl-helm-minikube `helm` | github-release `helm/helm` | |
| Node.js | feature-option | node `version` | node | |
| Playwright CLI | feature-option | `./features/playwright-cli` `version` | npm `@playwright/cli` | |
| Aspire CLI | feature-option | `./features/aspire` `version` | github-release `microsoft/aspire` | |
| each registry Feature | feature-ref | the 11 `ghcr.io/...:tag` keys | ghcr | One entry per Feature. |
| Claude Code | command | | | `claude update` |
| Codex | command | | | `codex update` |
| Angular CLI | command | | | `npm install -g @angular/cli@latest` |
| dotnet-ef | command | | | `dotnet tool update --global dotnet-ef --version '10.*'` |
| gh-stack | command | | | `gh extension upgrade gh-stack` |
| moodle-cs | command | | | `composer global update moodlehq/moodle-cs` |

Image-built tools (omp, herdr, t3code, Vale, and the rest) have no `command` entry. Updating them
in place would drift from the Dockerfile and be lost on the next rebuild.

## Version rules

**Granularity is preserved.** A pin keeps its number of components. `2.92` becomes the newest
`2.x` minor (`2.95`), `24.15` becomes `24.x`, `3.50.0` becomes the exact newest version, and a
Feature ref of `1` only ever moves to another major.

**Major bump.** A candidate is major when its first component differs from the current one. For
`0.x` versions, a change in the second component also counts as major (`0.9.1` to `0.10.0`), since
those projects break compatibility on minor releases.

**Two candidates per item.** Each item resolves the newest version in its current major and the
newest version overall. Only candidates newer than the current pin get a row. If the newest
overall is a major bump and there is also a newer in-major version, the item gets two rows: the
in-major candidate (checked) and the major candidate (unchecked). This keeps patch updates flowing when a new major exists (for example Node 24.x
while Node 26 is current). If both rows for one item are chosen, the major wins.

**Holds.** Items with `"hold": true` are not looked up and never appear in a checklist.
`update:check` and the summary list them as held, with their current value and `reason`.

## Verification

Runs before the checklist, so every row the developer sees is known to be installable.

- **Checksummed items:** download the candidate for each arch in the `arch` map (or once, with no
  arch) to a temp file and compute `sha256sum` of the file. The hashes are what get written. A
  failed download never produces a hash.
- **Items with a download `url` but no checksum:** fetch the first byte of each arch's URL
  (`curl -r 0-0 --fail`). GitHub's signed download URLs refuse `HEAD` requests.
- **Everything else:** no extra check; the lookup itself is the evidence.

Any failure skips the item with the reason, as described in the flow. `update:check` does not
verify; it only looks up versions.

## Applying edits

Edits are targeted line replacements, anchored by the manifest. `devcontainer.json` is never
parsed and rewritten as a whole, so comments and formatting survive.

- **`dockerfile-arg`**: replace the value on the line `ARG {arg}=`.
- **Per-arch checksum**: from the `ARG` line, find the first line starting `{arch})` (for example
  `amd64)`) that sets `{var}="`, and replace the quoted value. Once for each arch.
- **Single checksum**: replace the value on the line `ARG {sha256.arg}=`.
- **`base-image`**: replace the version part of the tag on the `FROM` line.
- **`feature-option`**: find the line holding the `"{feature}": {` key, then the first
  `"{option}": "` line before the block's closing brace, and replace the quoted value.
- **`feature-ref`**: replace the tag in the key on the `"{feature}:` line.

Before each item is applied, its file is copied to a temp snapshot. After each edit (the version
and each checksum), the value is read back through the same anchor and must equal what was
written. If any edit of an item fails, the file is restored from that item's snapshot, so edits
from earlier items and the developer's own uncommitted changes stay. The item is marked failed
and the run continues. Files are written in place (`printf ... > file`) to keep the inode.

After a `devcontainer.json` change, `npx @devcontainers/cli upgrade --workspace-folder .`
refreshes `.devcontainer/devcontainer-lock.json`. It also acts as a syntax check: if it fails,
`devcontainer.json` and the lock file are restored to how they were when the features step
started (never to git's version) and all Feature items from the run are marked failed (or, when
no Feature line changed, the lock refresh itself is). The features checklist also has its own item, **Refresh Feature lock file**, for picking
up new Feature patch releases when no version in `devcontainer.json` changed. It starts unchecked.

## Error handling

- **No terminal:** interactive tasks exit with a message pointing to `task update:check`.
- **Lookup or verification failure:** reported in the notice before the checklist; the item is
  skipped and the rest continue.
- **Cancel or Esc on a checklist:** skips that category and moves on to the next chosen one.
- **Ctrl-C:** aborts the run. A trap restores any file with an edit in progress and removes temp
  files.
- **Exit code:** non-zero if any chosen item failed. `update:check` exits non-zero only if a
  lookup failed; updates being available is not an error.

## Summary output

At the end of every run:

- Updated items: `name  old -> new`.
- Skipped items, with reasons (failed lookup, failed verification, not chosen).
- Failed items, with reasons.
- Held items, with their `reason`.
- `git diff --stat` for `.devcontainer/`.
- If pins or features changed, a reminder that a container rebuild is needed to use them.

`update:check` prints one table row per manifest item (except `command` entries): name, current,
newest in major, newest overall, and a status of `up to date`, `update`, `MAJOR`,
`held: <reason>`, or `error: <message>`.

## Testing

`scripts/update/test.sh` (run with `task update:test`) is plain bash with small assert helpers
and needs no network.

- **Unit tests:** version comparison, granularity preservation, major detection including the
  `0.x` rule, the two-candidate logic, and holds.
- **Fixture tests:** `test.sh` sources `update.sh` and replaces its network, dialog, lock-refresh,
  and repo-sync functions with stubs fed by per-test version lists and checksums. Each test gets
  fresh copies of the small files in `scripts/update/testdata/`. The tests check the exact
  resulting diff for each kind: an unquoted and a quoted `ARG`, a single checksum, per-arch
  checksums, the base image, a Feature option, and a Feature ref followed by an option edit in the
  same Feature. They also check that a failed edit restores the file, and they run every step
  (pins, features, tools, repos, check, all) through its checklist choices. Tests run under
  `set -e`, like the real script.
- **Real-file tests:** every entry in the real `tools.json` must be readable in the real
  `Dockerfile` and `devcontainer.json`, and every Dockerfile `ARG *_VERSION` and registry Feature
  must have an entry.
- **Live check:** `task update:check` against the real upstreams, run during implementation to
  confirm every source in the manifest resolves.

## Docs

- **README:** a new "Updating the Dev Container" section under "Using the Dev Container" (with a
  table of contents entry) covering the tasks, what each category changes, how majors and holds
  work, and that a rebuild is needed after pin or Feature changes.
- **AGENTS.md:** extend the rule "When adding a new tool to the dev container ... add a matching
  `check` line" so it also requires an entry in `scripts/update/tools.json` (or a `hold` with a
  reason, for a pin kept back on purpose).

## Out of scope

- Committing, pushing, opening PRs, or rebuilding the container.
- Scheduled or CI-driven update runs.
- Per-repo selection for `update:repos`.
- Changing the base image's .NET or Ubuntu suffix (`-10.0-noble`), which is a manual migration.
- Pins in files other than the Dockerfile and `devcontainer.json` (for example the Aspire SDK
  version in `Crucible.AppHost`).
