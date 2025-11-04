#!/usr/bin/env bash
set -euo pipefail

# make-branches.sh
# Create many dummy branches from a base branch (default: main).
#
# Usage examples:
#   ./make-branches.sh -n 200                # creates 200 branches locally: dummy-1..dummy-200
#   ./make-branches.sh -n 250 -p test- -r origin --push
#   ./make-branches.sh -n 50 -s 101 -p feature/  # create feature/101..feature/150
#
# WARNING: pushing many branches to a remote may be slow and could hit host rate limits.
# Use --dry-run to verify branch names before creating/pushing.

NUM=200
PREFIX="dummy-"
START=1
BASE="main"
REMOTE="origin"
PUSH=false
DRY_RUN=false

print_help() {
  cat <<EOF
Usage: $0 [options]
Options:
  -n N        Number of branches to create (default: $NUM)
  -p PREFIX   Branch name prefix (default: $PREFIX)
  -s START    Start index (default: $START)
  -b BASE     Base branch to branch from (default: $BASE)
  -r REMOTE   Remote name to push to (default: $REMOTE)
  --push      Push created branches to remote
  --dry-run   Print branch names without creating them
  -h          Show this help
EOF
}

# simple arg parsing (supports --push and --dry-run)
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NUM="$2"; shift 2;;
    -p) PREFIX="$2"; shift 2;;
    -s) START="$2"; shift 2;;
    -b) BASE="$2"; shift 2;;
    -r) REMOTE="$2"; shift 2;;
    --push) PUSH=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) print_help; exit 0;;
    *) ARGS+=("$1"); shift;;
  esac
done

# sanity checks
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

# Ensure no uncommitted changes (optional: you may want to allow but we guard by default)
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: you have uncommitted changes. Commit/stash them or run from a clean workspace." >&2
  exit 1
fi

# Make sure base branch exists locally or on remote
if ! git show-ref --verify --quiet "refs/heads/$BASE"; then
  # try to fetch base from remote
  echo "Base branch '$BASE' not found locally — attempting to fetch from remote '$REMOTE'..."
  git fetch "$REMOTE" "$BASE":"$BASE" || {
    echo "Failed to fetch base branch '$BASE' from remote '$REMOTE'." >&2
    exit 1
  }
fi

# Confirm base resolved
BASE_COMMIT=$(git rev-parse "$BASE") || { echo "Failed to resolve base branch '$BASE'"; exit 1; }
echo "Using base branch '$BASE' -> $BASE_COMMIT"

# prepare list and optionally create
END=$(( START + NUM - 1 ))

echo "Will create $NUM branches: ${PREFIX}${START} through ${PREFIX}${END}"
if $DRY_RUN; then
  echo "Dry-run enabled. Branches that would be created:"
  for ((i=START;i<=END;i++)); do
    echo "${PREFIX}${i}"
  done
  exit 0
fi

# Create branches locally without switching the working tree (fast)
for ((i=START;i<=END;i++)); do
  BR="${PREFIX}${i}"

  # If branch already exists, skip
  if git show-ref --verify --quiet "refs/heads/$BR"; then
    echo "Skipping existing local branch: $BR"
    continue
  fi

  # Create branch pointing at base commit
  git branch "$BR" "$BASE"
  echo "Created branch: $BR"

  if $PUSH; then
    # push branch to remote; do not set upstream to avoid altering local defaults
    # Use --no-verify to speedup hooks if any; omit if you want hooks to run
    git push "$REMOTE" "$BR" >/dev/null 2>&1 && echo "  Pushed: $REMOTE/$BR" || {
      echo "  Failed to push $BR to $REMOTE (continuing)..."
    }
  fi
done

echo "Done. Created branches: ${PREFIX}${START} .. ${PREFIX}${END}"
if $PUSH; then
  echo "Attempted to push created branches to remote '$REMOTE'."
fi

exit 0
