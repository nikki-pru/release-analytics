#!/bin/bash
set -euo pipefail

# Extract unique Jira ticket IDs from commits between two refs in a
# liferay-portal checkout, and emit ready-to-paste JQL for bug / security
# audit work.
#
# Runs from anywhere — the portal checkout path is resolved from
# config/config.yml (git.repo_path) or an explicit --repo override.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/config.yml"

OUTPUT_DIR="$SCRIPT_DIR/output"
TICKET_LIST="$OUTPUT_DIR/ticketList.txt"

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") <previousGitID> <newGitID> [--repo <path>]

Arguments:
  previousGitID   Earlier git ref (tag, branch, or SHA)
  newGitID        Later git ref
  --repo <path>   Override portal checkout path
                  (defaults to git.repo_path in $CONFIG_FILE)

Output:
  $TICKET_LIST   — unique ticket IDs, one per line
  stdout         — unique ticket list + JQL snippets
EOF
	exit 1
}

if [[ $# -lt 2 ]]; then
	usage
fi

previousGitID="$1"
newGitID="$2"
shift 2

REPO_PATH=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--repo)
			REPO_PATH="${2:-}"
			if [[ -z "$REPO_PATH" ]]; then
				echo "Error: --repo requires a path argument" >&2
				exit 1
			fi
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			echo "Error: unknown argument: $1" >&2
			usage
			;;
	esac
done

# Resolve repo path from config.yml if not overridden
if [[ -z "$REPO_PATH" ]]; then
	if [[ ! -f "$CONFIG_FILE" ]]; then
		echo "Error: config file not found: $CONFIG_FILE" >&2
		echo "       Pass --repo <path> or create config/config.yml" >&2
		exit 1
	fi
	REPO_PATH=$(awk '
		/^git:/                                { in_git=1; next }
		/^[^[:space:]]/                        { in_git=0 }
		in_git && /^[[:space:]]+repo_path:/ {
			sub(/^[[:space:]]+repo_path:[[:space:]]*/, "")
			gsub(/^["\x27]|["\x27]$/, "")
			print
			exit
		}
	' "$CONFIG_FILE")
fi

if [[ -z "$REPO_PATH" ]]; then
	echo "Error: git.repo_path not set in $CONFIG_FILE and --repo not provided" >&2
	exit 1
fi

# Expand leading ~/ — config.yml often stores repo_path as ~/dev/...
REPO_PATH="${REPO_PATH/#\~\//$HOME/}"

if [[ ! -d "$REPO_PATH/.git" ]]; then
	echo "Error: not a git repository: $REPO_PATH" >&2
	exit 1
fi

# Validate refs before doing work
for ref in "$previousGitID" "$newGitID"; do
	if ! git -C "$REPO_PATH" rev-parse --verify --quiet "$ref" >/dev/null; then
		echo "Error: ref not found in $REPO_PATH: $ref" >&2
		exit 1
	fi
done

mkdir -p "$OUTPUT_DIR"

# Collect unique tickets and other commit prefixes
declare -A seen=()
unique_tickets=()    # well-formed: PROJECT-NUMBER
other_prefixes=()    # everything else (Merge, Revert, free-text, etc.)
lpd_tickets=()       # LPD subset — feeds the JQL

while IFS= read -r subject; do
	# First whitespace-delimited token of the commit subject
	token="${subject%%[[:space:]]*}"

	# Skip empty subjects
	[[ -z "$token" ]] && continue

	# Extract leading ticket ID if present — catches branch-named prefixes
	# like "LPD-79852-release-2025.q1" as LPD-79852.
	if [[ "$token" =~ ^([A-Z]+-[0-9]+) ]]; then
		ticket="${BASH_REMATCH[1]}"

		# Dedup on the extracted ticket ID
		[[ -n "${seen[$ticket]:-}" ]] && continue
		seen[$ticket]=1

		unique_tickets+=("$ticket")

		# Only LPD tickets feed the JQL (project = LPD is hardcoded)
		if [[ "$ticket" =~ ^LPD- ]]; then
			lpd_tickets+=("$ticket")
		fi
	else
		# Non-ticket prefix (Merge, Revert, free text) — dedup on raw token
		[[ -n "${seen[$token]:-}" ]] && continue
		seen[$token]=1
		other_prefixes+=("$token")
	fi
done < <(git -C "$REPO_PATH" log --format='%s' "${previousGitID}...${newGitID}")

# Write artifact (empty file if no tickets found, rather than stale prior run)
: > "$TICKET_LIST"
if [[ ${#unique_tickets[@]} -gt 0 ]]; then
	printf '%s\n' "${unique_tickets[@]}" > "$TICKET_LIST"
fi

# Build comma-separated JQL list
jql_list=""
if [[ ${#lpd_tickets[@]} -gt 0 ]]; then
	printf -v jql_list '%s,' "${lpd_tickets[@]}"
	jql_list="${jql_list%,}"
fi

# Report
echo
echo "Unique tickets >>>"
echo
if [[ ${#unique_tickets[@]} -gt 0 ]]; then
	printf '%s\n' "${unique_tickets[@]}"
else
	echo "(none)"
fi

echo
echo "Other commit prefixes (excluded from JQL) >>>"
echo
if [[ ${#other_prefixes[@]} -gt 0 ]]; then
	printf '%s\n' "${other_prefixes[@]}"
else
	echo "(none)"
fi

cat <<EOF

===========
For JQL >>>

key in (${jql_list}) and project = LPD and type = bug

Security Vulnerabilities >>>

key in (${jql_list}) and project = LPD and type = bug and (component in ("security vulnerability","Security Vulnerability") OR "Cross Cutting Properties[Checkboxes]" in ("Security Vulnerability"))

===========

Repo:            $REPO_PATH
Range:           ${previousGitID}...${newGitID}
Unique tickets:  ${#unique_tickets[@]}
Other prefixes:  ${#other_prefixes[@]}
LPD in JQL:      ${#lpd_tickets[@]}
Artifact:        $TICKET_LIST
EOF
