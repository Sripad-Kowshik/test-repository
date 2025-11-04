#!/usr/bin/env bash
set -euo pipefail

# make-branches-with-retry.sh
# Create many dummy branches from a base branch, make a unique commit on each,
# and reliably push branches to remote with retries. If a previous run created
# branches locally but failed to push them, re-running with --push will
# attempt to push those existing local branches as well.
#
# Usage examples:
#  ./make-branches-with-retry.sh -n 200 --push
#  ./make-branches-with-retry.sh -n 50 -p feat/ -s 101 --push --batch 10 --delay 2 --retries 5
#
# IMPORTANT: Run from a clean working tree (no uncommitted changes).

NUM=200
PREFIX="dummy-"
START=1
BASE="main"
REMOTE="origin"
PUSH=false
DRY_RUN=false
INFO_FILE=".branch-info"
COMMIT_MSG="chore: add branch metadata {{BRANCH}}"
AUTHOR_NAME="Test Bot"
AUTHOR_EMAIL="test@example.com"
RETRIES=3        # attempts for pushing a single branch
DELAY=1          # seconds to wait between pushes (and between retries)
BATCH=20         # number of pushes after which we sleep a bit more
BATCH_SLEEP=5

print_help() {
  cat <<EOF
Usage: $0 [options]
Options:
  -n N           Number of branches to create (default: $NUM)
  -p PREFIX      Branch name prefix (default: $PREFIX)
  -s START       Start index (default: $START)
  -b BASE        Base branch to branch from (default: $BASE)
  -r REMOTE      Remote name to push to (default: $REMOTE)
  --push         Push created branches to remote (and attempt to push already-existing local branches)
  --dry-run      Print branch names and actions without creating them
  -f FILE        File path to write per-branch metadata (default: $INFO_FILE)
  -a NAME        Commit author name (default: $AUTHOR_NAME)
  -e EMAIL       Commit author email (default: $AUTHOR_EMAIL)
  --retries N    Number of push retries per branch (default: $RETRIES)
  --delay S      Delay seconds between pushes/retries (default: $DELAY)
  --batch N      After N pushes, sleep BATCH_SLEEP seconds (default: $BATCH)
  -h             Show this help
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NUM="$2"; shift 2;;
    -p) PREFIX="$2"; shift 2;;
    -s) START="$2"; shift 2;;
    -b) BASE="$2"; shift 2;;
    -r) REMOTE="$2"; shift 2;;
    --push) PUSH=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    -f) INFO_FILE="$2"; shift 2;;
    -a) AUTHOR_NAME="$2"; shift 2;;
    -e) AUTHOR_EMAIL="$2"; shift 2;;
    --retries) RETRIES="$2"; shift 2;;
    --delay) DELAY="$2"; shift 2;;
    --batch) BATCH="$2"; shift 2;;
    -h|--help) print_help; exit 0;;
    *) echo "Unknown arg: $1"; print_help; exit 1;;
  esac
done

# sanity checks
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: you have uncommitted changes. Commit or stash them and re-run." >&2
  exit 1
fi

# ensure base exists locally (try to fetch if not)
if ! git show-ref --verify --quiet "refs/heads/$BASE"; then
  echo "Base branch '$BASE' not found locally — attempting to fetch from remote '$REMOTE'..."
  git fetch "$REMOTE" "$BASE":"$BASE" || {
    echo "Failed to fetch base branch '$BASE' from remote '$REMOTE'." >&2
    exit 1
  }
fi

BASE_COMMIT=$(git rev-parse "$BASE") || { echo "Failed to resolve base branch '$BASE'"; exit 1; }
echo "Using base branch '$BASE' -> $BASE_COMMIT"

END=$(( START + NUM - 1 ))
echo "Target branches: ${PREFIX}${START} .. ${PREFIX}${END}"
if $DRY_RUN; then
  echo "(dry-run) Will create (or push existing) branches:"
  for ((i=START;i<=END;i++)); do
    echo "  - ${PREFIX}${i}"
  done
  exit 0
fi

# record original branch to restore later
ORIG_BRANCH=$(git symbolic-ref --quiet --short HEAD || git rev-parse --short HEAD)
cleanup() {
  echo "Restoring original branch: $ORIG_BRANCH"
  # try normal switch first, else detach to the commit
  git switch --quiet "$ORIG_BRANCH" || git switch --detach "$ORIG_BRANCH" || true
}
trap cleanup EXIT

# Helper: check if remote has branch
remote_has_branch() {
  local br="$1"
  # ls-remote returns something if branch exists
  if git ls-remote --heads "$REMOTE" "refs/heads/$br" | grep -q .; then
    return 0
  else
    return 1
  fi
}

# Helper: push a branch with retries
push_branch_with_retries() {
  local br="$1"
  local tries=0

  while (( tries < RETRIES )); do
    ((tries++))
    echo "  push attempt $tries/$RETRIES for $br ..."
    # push & set upstream if not set; we push the local branch ref to remote
    if git push --set-upstream "$REMOTE" "$br" >/dev/null 2>&1; then
      echo "    pushed: $REMOTE/$br"
      return 0
    else
      echo "    push failed for $br (attempt $tries)."
      sleep "$DELAY"
    fi
  done

  echo "  All $RETRIES push attempts failed for $br — will continue and you can retry later." >&2
  return 1
}

# Make sure we start from the base
git switch --quiet "$BASE"

push_count=0

for ((i=START;i<=END;i++)); do
  BR="${PREFIX}${i}"

  if git show-ref --verify --quiet "refs/heads/$BR"; then
    echo "Local branch exists: $BR"
    # local exists -> ensure it has a commit (it should). If remote missing and user asked to push, attempt push.
    if $PUSH; then
      if remote_has_branch "$BR"; then
        echo "  remote already has $BR, skipping push."
      else
        echo "  remote missing $BR -> attempting to push with retries..."
        push_branch_with_retries "$BR" && ((push_count++)) || true
        sleep "$DELAY"
      fi
    else
      echo "  (not pushing; use --push to push branches)"
    fi
    # continue to next branch (do not create/recreate)
    continue
  fi

  # branch does not exist locally -> create it, commit unique metadata, then push if requested
  echo "Creating branch '$BR' from '$BASE'..."
  git switch -c "$BR" "$BASE"

  TOKEN=$(head -c 12 /dev/urandom | od -An -t x1 | tr -d ' \n')
  echo "branch: $BR" > "$INFO_FILE"
  echo "base: $BASE" >> "$INFO_FILE"
  echo "created_at: $(date --utc +"%Y-%m-%dT%H:%M:%SZ")" >> "$INFO_FILE"
  echo "token: $TOKEN" >> "$INFO_FILE"

  git add --force "$INFO_FILE"
  COMMIT_MSG_ACTUAL="${COMMIT_MSG//\{\{BRANCH\}\}/$BR}"

  GIT_AUTHOR_NAME="$AUTHOR_NAME" \
  GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="$AUTHOR_NAME" \
  GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
  git commit -m "$COMMIT_MSG_ACTUAL" --no-verify >/dev/null

  echo "  committed on $BR: $INFO_FILE (token $TOKEN)"

  if $PUSH; then
    echo "  pushing $BR -> $REMOTE/$BR ..."
    if push_branch_with_retries "$BR"; then
      ((push_count++))
    fi
    sleep "$DELAY"
  fi

  # switch back to base to start next iteration cleanly
  git switch --quiet "$BASE"

  # occasional longer pause to avoid hitting rate limits
  if (( push_count > 0 && (push_count % BATCH) == 0 )); then
    echo "Completed $push_count pushes so far — sleeping ${BATCH_SLEEP}s to reduce rate-limit risk..."
    sleep "$BATCH_SLEEP"
  fi
done

echo "Done. Processed branches: ${PREFIX}${START} .. ${PREFIX}${END}"
if $PUSH; then
  echo "Attempted pushes: $push_count"
  echo "Branches that failed to push (if any) remain as local branches and will be retried on the next run."
else
  echo "No pushes were attempted (run with --push to push branches and retry previously-unpushed local branches)."
fi

exit 0