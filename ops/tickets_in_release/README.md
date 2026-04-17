# Tickets in Release

Extracts unique Jira ticket IDs from commits between two refs in a `liferay-portal` checkout and emits ready-to-paste JQL for release bug / security audit work.

Runs from anywhere — the portal path is resolved from `config/config.yml` or via an explicit `--repo` override.

---

## Usage

```bash
bash ops/tickets_in_release/tickets-in-release.sh <previousGitID> <newGitID> [--repo <path>]
```

### Arguments

| Argument | Required | Description |
|---|---|---|
| `previousGitID` | yes | Earlier git ref (tag, branch, or SHA). Must exist in the target repo. |
| `newGitID` | yes | Later git ref. Must exist in the target repo. |
| `--repo <path>` | no | Override portal checkout path. Defaults to `git.repo_path` from `config/config.yml`. |

### Examples

```bash
# Uses git.repo_path from config/config.yml
bash ops/tickets_in_release/tickets-in-release.sh b4fcc1b46664f release-2026.q1.23

# Explicit repo override
bash ops/tickets_in_release/tickets-in-release.sh 2026.q1.22 release-2026.q1.23 --repo ~/dev/projects/liferay-portal
```

---

## Configuration

The script reads `git.repo_path` from `config/config.yml` to find the `liferay-portal` checkout. This key already exists in `config/config.yml.example` — copy the example and fill it in:

```yaml
git:
  repo_path: ~/dev/projects/liferay-portal
  base_branch: master
```

Leading `~/` in `repo_path` is expanded to `$HOME/`. Pass `--repo <path>` to bypass the config entirely.

---

## What it does

1. Resolves the target repo from `--repo` or `git.repo_path` in config.
2. Validates both refs exist in that repo before doing any work.
3. Runs `git -C <repo> log --format='%s' <prev>...<new>` to collect commit subject lines.
4. For each subject, takes the first whitespace-delimited token and extracts a leading ticket ID (`^[A-Z]+-[0-9]+`). Branch-named prefixes like `LPD-79852-release-2026.q1` are normalized to `LPD-79852`.
5. Deduplicates on the extracted ticket ID.
6. Buckets results into:
   - **Unique tickets** — all well-formed ticket IDs. Written to `output/ticketList.txt` and printed.
   - **Other commit prefixes** — non-ticket tokens (merge commits, reverts, free-text subjects). Printed for visibility, not written to the artifact, not included in JQL.
   - **LPD tickets** — the `LPD-`-prefixed subset, used to build the JQL snippets.

---

## Output

### Console

```
Unique tickets >>>

LPD-84426
LPD-83363
LPD-79852
...

Other commit prefixes (excluded from JQL) >>>

Merge
Revert

===========
For JQL >>>

key in (LPD-84426,LPD-83363,...) and project = LPD and type = bug

Security Vulnerabilities >>>

key in (LPD-84426,LPD-83363,...) and project = LPD and type = bug and (component in ("security vulnerability","Security Vulnerability") OR "Cross Cutting Properties[Checkboxes]" in ("Security Vulnerability"))

===========

Repo:            /home/nikki/dev/projects/liferay-portal
Range:           b4fcc1b46664f...release-2026.q1.23
Unique tickets:  96
Other prefixes:  0
LPD in JQL:      96
Artifact:        ops/tickets_in_release/output/ticketList.txt
```

### File artifact

`output/ticketList.txt` — one ticket ID per line, ticket-shaped only. Overwritten on every run. The `output/` directory is gitignored at the project level.

---

## Caveats

- **JQL is hardcoded to `project = LPD`.** Non-LPD ticket IDs (e.g. `LPS-`, `LPP-`) are listed in the unique tickets section and written to `ticketList.txt`, but excluded from both JQL snippets. Edit the heredoc at the bottom of the script if you need a different project filter.
- **"Other commit prefixes" are visible but non-actionable.** Merge commits, reverts, and non-ticket subjects show up in their own section so you can eyeball whether anything important got missed. They do not feed the JQL or the artifact.
- **`output/ticketList.txt` is overwritten** on every run. Copy it elsewhere if you need to preserve a prior extraction.
- **Ref validation is strict.** If either ref doesn't resolve in the target repo, the script aborts before running `git log`. Fetch the tag or branch first (`git fetch upstream-ee tag <tagname>`) if it's not already local.

---

## Dependencies

- Bash 4+ (uses associative arrays, regex capture into `BASH_REMATCH`, and `${var/#pattern/replacement}` expansion)
- `git`
- Either `config/config.yml` with `git.repo_path` set, or `--repo <path>` passed explicitly
- Target path must be a git repository
