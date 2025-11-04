#!/usr/bin/env bash
set -euo pipefail

# make-branches-plumbing.sh
# Create many dummy branches from a base branch and make a unique commit on each,
# without checking out branches (no working-tree switches). Pushes with retries.
#
# Usage:
#  ./make-branches-plumbing.sh -n 200 --push
#  ./make-branches-plumbing.sh -n 50 -p feat/ -s 101 --push --retries 5 --delay 2
#
# WARNING: This manipulates refs and objects directly (safe when used responsibly).
# IMPORTANT: Run from repo root. A clean working tree is NOT strictly required because we never switch,
# but avoid running on a repo with concurrent git processes to be safe.

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
RETRIES=3
DELAY=1
BATCH=20
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

# arg parse
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

# sanity
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

# Resolve base commit
if ! BASE_COMMIT=$(git rev-parse "$BASE" 2>/dev/null); then
  echo "Base branch '$BASE' not found locally. Attempting to fetch from $REMOTE..."
  git fetch "$REMOTE" "$BASE":"$BASE" || { echo "Failed to fetch base $BASE"; exit 1; }
  BASE_COMMIT=$(git rev-parse "$BASE") || { echo "Failed to resolve base commit after fetch"; exit 1; }
fi
BASE_TREE=$(git rev-parse "$BASE":"$INFO_FILE" >/dev/null 2>&1 && echo "unused" || true) # noop - just clarity

END=$(( START + NUM - 1 ))
echo "Target branches: ${PREFIX}${START} .. ${PREFIX}${END}"

if $DRY_RUN; then
  echo "(dry-run) Would create branches and commits (no changes made):"
  for ((i=START;i<=END;i++)); do
    BR="${PREFIX}${i}"
    MSG="${COMMIT_MSG//\{\{BRANCH\}\}/$BR}"
    echo "  - $BR  -> commit msg: \"$MSG\"  -> file: $INFO_FILE"
  done
  exit 0
fi

# helper: check remote branch existence
remote_has_branch() {
  local br="$1"
  if git ls-remote --heads "$REMOTE" "refs/heads/$br" | grep -q .; then
    return 0
  else
    return 1
  fi
}

# helper: push with retries (no set -e escape; we handle return codes)
push_branch_with_retries() {
  local br="$1"
  local tries=0
  while (( tries < RETRIES )); do
    ((tries++))
    echo "  push attempt $tries/$RETRIES for $br ..."
    if git push --set-upstream "$REMOTE" "refs/heads/$br:refs/heads/$br" >/dev/null 2>&1; then
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

push_count=0

for ((i=START;i<=END;i++)); do
  BR="${PREFIX}${i}"

  # If local branch exists, we will not recreate it; we will try to push if requested and remote missing
  if git show-ref --verify --quiet "refs/heads/$BR"; then
    echo "Local branch exists: $BR"
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
    # next
    continue
  fi

  echo "Creating branch '$BR' (commit created without checkout) from commit $BASE_COMMIT ..."

  # Create a temporary index and write tree with new .branch-info
  TMP_INDEX="$(mktemp)"
  export GIT_INDEX_FILE="$TMP_INDEX"

  # populate index with base commit tree
  git read-tree "$BASE_COMMIT" >/dev/null

  # create metadata file content in a temp file
  TOK=$(head -c 12 /dev/urandom | od -An -t x1 | tr -d ' \n')
  CREATED_AT=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")
  printf 'branch: %s\nbase: %s\ncreated_at: %s\ntoken: %s\n' "$BR" "$BASE" "$CREATED_AT" "$TOK" > "$INFO_FILE.tmp"

  # write blob and add to index
  BLOB_HASH=$(git hash-object -w "$INFO_FILE.tmp")
  # ensure index sees it
  git update-index --add --cacheinfo 100644 "$BLOB_HASH" "$INFO_FILE" >/dev/null

  # write-tree to get new tree object
  TREE_HASH=$(git write-tree)

  # prepare commit message and create commit with parent = base commit
  COMMIT_MSG_ACTUAL="${COMMIT_MSG//\{\{BRANCH\}\}/$BR}"

  # create commit with proper author/committer env vars
  GIT_AUTHOR_NAME="$AUTHOR_NAME" \
  GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
  GIT_COMMITTER_NAME="$AUTHOR_NAME" \
  GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
  COMMIT_HASH=$(echo "$COMMIT_MSG_ACTUAL" | git commit-tree "$TREE_HASH" -p "$BASE_COMMIT")

  # create branch ref pointing to new commit
  git update-ref "refs/heads/$BR" "$COMMIT_HASH"

  echo "  created branch $BR -> commit $COMMIT_HASH (token $TOK)"

  # cleanup temp index and file
  unset GIT_INDEX_FILE
  rm -f "$TMP_INDEX" "$INFO_FILE.tmp"

  # If push requested, attempt it
  if $PUSH; then
    echo "  pushing $BR -> $REMOTE/$BR ..."
    if push_branch_with_retries "$BR"; then
      ((push_count++))
    fi
    sleep "$DELAY"
  fi

  # batch sleep to avoid hitting remote rate limits
  if (( push_count > 0 && (push_count % BATCH) == 0 )); then
    echo "Completed $push_count pushes so far — sleeping ${BATCH_SLEEP}s to reduce rate-limit risk..."
    sleep "$BATCH_SLEEP"
  fi
done

echo "Done. Created/processed branches: ${PREFIX}${START} .. ${PREFIX}${END}"
if $PUSH; then
  echo "Attempted pushes: $push_count"
  echo "Branches that failed to push (if any) remain as local branches and will be retried on the next run."
else
  echo "No pushes were attempted (run with --push to push branches and retry previously-unpushed local branches)."
fi

exit 0