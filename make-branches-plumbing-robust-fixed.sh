#!/usr/bin/env bash
# make-branches-plumbing-robust-fixed.sh
# Robust plumbing branch creator with safe cleanup (fixes unbound GIT_INDEX_FILE issue).
set -euo pipefail

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
FAILED_LOG="failed-branches.log"

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

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

# Resolve base commit (ensure commit object)
if ! BASE_COMMIT=$(git rev-parse --verify "$BASE^{commit}" 2>/dev/null); then
  echo "Base branch '$BASE' not found locally. Attempting to fetch from $REMOTE..."
  git fetch "$REMOTE" "$BASE":"$BASE" || { echo "Failed to fetch base $BASE"; exit 1; }
  BASE_COMMIT=$(git rev-parse --verify "$BASE^{commit}") || { echo "Failed to resolve base commit after fetch"; exit 1; }
fi

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
  git ls-remote --heads "$REMOTE" "refs/heads/$br" | grep -q . || return 1
}

# helper: push with retries
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
  echo "  All $RETRIES push attempts failed for $br." >&2
  return 1
}

# ensure failed log is empty for this run
: > "$FAILED_LOG"

push_count=0

for ((i=START;i<=END;i++)); do
  BR="${PREFIX}${i}"
  echo "==== Processing: $BR ===="

  # If local branch exists already:
  if git show-ref --verify --quiet "refs/heads/$BR"; then
    echo "Local branch exists: $BR"
    if $PUSH; then
      if remote_has_branch "$BR"; then
        echo "  remote already has $BR, skipping push."
      else
        echo "  remote missing $BR -> attempting to push with retries..."
        if push_branch_with_retries "$BR"; then
          ((push_count++))
        else
          echo "$BR" >> "$FAILED_LOG"
        fi
        sleep "$DELAY"
      fi
    else
      echo "  (not pushing; use --push to push branches)"
    fi
    continue
  fi

  # Perform creation inside a guarded subshell so errors don't abort main script
  if ! (
    set -e

    # prepare temp files and ensure cleanup within subshell
    TMP_INDEX="$(mktemp)"
    TMP_META="$(mktemp)"
    # use a subshell-local GIT_INDEX_FILE; parent not affected
    export GIT_INDEX_FILE="$TMP_INDEX"

    # populate index with base commit's tree (use commit^{tree} to avoid errors)
    git read-tree "$BASE_COMMIT^{tree}" >/dev/null

    # create metadata file
    TOK=$(head -c 12 /dev/urandom | od -An -t x1 | tr -d ' \n')
    CREATED_AT=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")
    printf 'branch: %s\nbase: %s\ncreated_at: %s\ntoken: %s\n' "$BR" "$BASE" "$CREATED_AT" "$TOK" > "$TMP_META"

    # write blob object and add to index
    BLOB_HASH=$(git hash-object -w "$TMP_META")
    git update-index --add --cacheinfo 100644 "$BLOB_HASH" "$INFO_FILE" >/dev/null

    # write new tree
    TREE_HASH=$(git write-tree)

    # commit message and create commit with proper author/committer env vars
    COMMIT_MSG_ACTUAL="${COMMIT_MSG//\{\{BRANCH\}\}/$BR}"
    GIT_AUTHOR_NAME="$AUTHOR_NAME" \
    GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$AUTHOR_NAME" \
    GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    COMMIT_HASH=$(echo "$COMMIT_MSG_ACTUAL" | git commit-tree "$TREE_HASH" -p "$BASE_COMMIT")

    # create local branch ref
    git update-ref "refs/heads/$BR" "$COMMIT_HASH"

    echo "  created branch $BR -> commit $COMMIT_HASH (token $TOK)"

    # cleanup temp index and meta file inside subshell
    unset GIT_INDEX_FILE
    rm -f "$TMP_INDEX" "$TMP_META" || true

    # attempt push if requested
    if $PUSH; then
      echo "  pushing $BR -> $REMOTE/$BR ..."
      if git push --set-upstream "$REMOTE" "refs/heads/$BR:refs/heads/$BR" >/dev/null 2>&1; then
        echo "    pushed: $REMOTE/$BR"
        exit 0
      else
        # If push failed, we still exit with non-zero to let outer script record failure
        echo "    initial push failed for $BR" >&2
        exit 2
      fi
    fi

    exit 0
  ); then
    # subshell succeeded -> if pushed counted, increment
    if $PUSH && remote_has_branch "$BR"; then
      ((push_count++))
    fi
    echo "OK: $BR"
  else
    # subshell failed
    echo "FAILED: $BR (see $FAILED_LOG)"
    echo "$BR" >> "$FAILED_LOG"

    # try safe cleanup of any tmp index file if left in environment
    if [ -n "${GIT_INDEX_FILE-}" ]; then
      rm -f "${GIT_INDEX_FILE}" 2>/dev/null || true
    fi

    # continue to next branch (do not exit)
    continue
  fi

  # small delay to be gentle with host when pushing many branches
  if $PUSH; then
    sleep "$DELAY"
    if (( push_count > 0 && (push_count % BATCH) == 0 )); then
      echo "Completed $push_count pushes so far — sleeping ${BATCH_SLEEP}s to reduce rate-limit risk..."
      sleep "$BATCH_SLEEP"
    fi
  fi
done

echo "Done. Processed branches: ${PREFIX}${START} .. ${PREFIX}${END}"
if $PUSH; then
  echo "Attempted pushes: $push_count"
  if [[ -s "$FAILED_LOG" ]]; then
    echo "Some branches failed (logged to $FAILED_LOG). Re-run to retry."
  else
    echo "No push failures logged."
  fi
else
  echo "No pushes were attempted (run with --push to push branches and retry previously-unpushed local branches)."
fi

exit 0