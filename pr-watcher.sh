#!/usr/bin/env bash
set -euo pipefail

# Set this to your home directory (e.g. /Users/yourname)
USER_DIR="/Users/rhonalf.martinez"

SKILLS_DIR="$USER_DIR/projects/claude-skills/pr-cycle/skills"
STATE_FILE="$USER_DIR/projects/pr-watcher/pr-watcher-state.json"
LOG_FILE="$USER_DIR/.claude/logs/pr-watcher.log"
CLAUDE_BIN="$USER_DIR/.local/bin/claude"
GH_BIN="/opt/homebrew/bin/gh"
LOCK_FILE="/tmp/pr-watcher.lock"
CLAUDE_TIMEOUT=600  # 10 min max per review
MAX_REVIEWS_PER_RUN=5

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

rotate_log() {
  local max_lines=2000
  if [[ -f "$LOG_FILE" ]]; then
    local line_count
    line_count=$(wc -l < "$LOG_FILE")
    if [[ "$line_count" -gt "$max_lines" ]]; then
      tail -n "$max_lines" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

# Lock — prevent concurrent runs
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another instance is running. Exiting."
  exit 0
fi

rotate_log

# Work hours check: Mon-Fri, 8am-7pm COT (UTC-5)
HOUR=$(TZ="America/Bogota" date +%H)
DOW=$(TZ="America/Bogota" date +%u)  # 1=Mon 7=Sun
if [[ "$DOW" -gt 5 || "$HOUR" -lt 8 || "$HOUR" -ge 19 ]]; then
  log "Outside work hours, skipping."
  exit 0
fi

log "Starting PR watcher run."

# Resolve GitHub login dynamically
GH_LOGIN=$("$GH_BIN" api user --jq '.login' 2>/dev/null) || {
  log "ERROR: Could not resolve GitHub login. Is gh authenticated?"
  exit 1
}
log "Watching PRs for: $GH_LOGIN"

# Load state
if [[ -f "$STATE_FILE" ]]; then
  STATE=$(cat "$STATE_FILE")
else
  STATE='{"reviewed":{}}'
fi

# Fetch PRs where review is requested
PRS=$("$GH_BIN" api graphql -f query="
{
  search(query: \"is:pr is:open review-requested:$GH_LOGIN\", type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number
        title
        headRefOid
        url
        headRepository {
          name
          nameWithOwner
        }
      }
    }
  }
}" --jq '.data.search.nodes' 2>/dev/null) || {
  log "ERROR: GitHub API request failed."
  exit 1
}

if [[ -z "$PRS" || "$PRS" == "null" ]]; then
  log "ERROR: Could not parse PR list from GitHub API."
  exit 1
fi

PR_COUNT=$(echo "$PRS" | jq 'length')
log "Found $PR_COUNT open PR(s) awaiting review."

if [[ "$PR_COUNT" -eq 0 ]]; then
  log "No PRs to review."
  exit 0
fi

REVIEWED=0
SKIPPED=0
UNKNOWN=0

for i in $(seq 0 $((PR_COUNT - 1))); do
  if [[ "$REVIEWED" -ge "$MAX_REVIEWS_PER_RUN" ]]; then
    log "Reached MAX_REVIEWS_PER_RUN=$MAX_REVIEWS_PER_RUN. Stopping."
    break
  fi

  PR=$(echo "$PRS" | jq ".[$i]")
  PR_NUMBER=$(echo "$PR" | jq -r '.number')
  PR_TITLE=$(echo "$PR" | jq -r '.title')
  CURRENT_SHA=$(echo "$PR" | jq -r '.headRefOid')
  REPO_OWNER=$(echo "$PR" | jq -r '.headRepository.nameWithOwner' | cut -d'/' -f1)
  REPO_NAME=$(echo "$PR" | jq -r '.headRepository.nameWithOwner' | cut -d'/' -f2)
  STATE_KEY="$REPO_OWNER/$REPO_NAME#$PR_NUMBER"

  log "Checking $STATE_KEY (SHA: ${CURRENT_SHA:0:8})"

  LAST_SHA=$(echo "$STATE" | jq -r --arg key "$STATE_KEY" '.reviewed[$key] // ""')
  if [[ "$LAST_SHA" == "$CURRENT_SHA" ]]; then
    log "SKIPPED: $STATE_KEY — already reviewed at current SHA"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Clone into a tmp dir, clean up explicitly after each iteration
  TMP_DIR=$(mktemp -d)
  cleanup_tmp() { rm -rf "$TMP_DIR"; }

  log "Cloning $REPO_OWNER/$REPO_NAME to detect stack..."
  if ! "$GH_BIN" repo clone "$REPO_OWNER/$REPO_NAME" "$TMP_DIR" -- --depth=1 --quiet 2>/dev/null; then
    log "ERROR: Could not clone $REPO_OWNER/$REPO_NAME — skipping"
    cleanup_tmp
    UNKNOWN=$((UNKNOWN + 1))
    continue
  fi

  pushd "$TMP_DIR" > /dev/null
  "$GH_BIN" pr checkout "$PR_NUMBER" --quiet 2>/dev/null || true

  # Detect stack
  SKILL=""
  if [[ -f "Gemfile" ]]; then
    SKILL="backend-rails"
  elif [[ -f "composer.json" ]] && find . -maxdepth 4 -name "functions.php" -quit 2>/dev/null | grep -q .; then
    SKILL="backend-wordpress"
  elif [[ -f "composer.json" ]]; then
    SKILL="backend-yii2"
  elif find . -maxdepth 3 -name "*.liquid" 2>/dev/null | grep -q .; then
    SKILL="frontend-shopify"
  elif [[ -f "package.json" ]]; then
    SKILL="frontend-nextjs"
  fi

  popd > /dev/null
  cleanup_tmp

  if [[ -z "$SKILL" ]]; then
    log "UNKNOWN stack for $STATE_KEY — sending notification"
    timeout "$CLAUDE_TIMEOUT" "$CLAUDE_BIN" --dangerously-skip-permissions -p \
      "Send a push notification with this exact message: PR #$PR_NUMBER en $REPO_NAME — stack desconocido, revision manual requerida" \
      2>/dev/null || true
    UNKNOWN=$((UNKNOWN + 1))
    continue
  fi

  SKILL_FILE="$SKILLS_DIR/$SKILL/SKILL.md"
  if [[ ! -f "$SKILL_FILE" ]]; then
    log "ERROR: Skill file not found: $SKILL_FILE — skipping"
    UNKNOWN=$((UNKNOWN + 1))
    continue
  fi

  log "Running $SKILL review for $STATE_KEY..."

  SKILL_CONTENT=$(cat "$SKILL_FILE")

  PROMPT="You are running an automated PR review. The repo is $REPO_OWNER/$REPO_NAME and the PR number is $PR_NUMBER.

IMPORTANT RULES:
- COMMENT_LANGUAGE=en (post all GitHub comments in English)
- Run Steps 0 through 6 of the skill only. STOP after Step 6.
- Do NOT move any Jira ticket. Do NOT approve or merge. Do NOT do anything after Step 6.
- After completing Step 6, send a push notification with this exact text: PR listo para tu veredicto: $REPO_NAME #$PR_NUMBER — $PR_TITLE

Here is the skill to execute:

$SKILL_CONTENT"

  if timeout "$CLAUDE_TIMEOUT" "$CLAUDE_BIN" --dangerously-skip-permissions -p "$PROMPT" \
      --allowedTools "Bash,Read,Glob,Grep,Agent" \
      2>>"$LOG_FILE"; then

    # Update and persist state
    STATE=$(echo "$STATE" | jq --arg key "$STATE_KEY" --arg sha "$CURRENT_SHA" '.reviewed[$key] = $sha')
    echo "$STATE" > "$STATE_FILE"
    log "REVIEWED: $STATE_KEY with skill $SKILL"
    REVIEWED=$((REVIEWED + 1))
  else
    EXIT_CODE=$?
    if [[ "$EXIT_CODE" -eq 124 ]]; then
      log "TIMEOUT: $STATE_KEY — claude exceeded ${CLAUDE_TIMEOUT}s limit"
    else
      log "ERROR: claude failed (exit $EXIT_CODE) for $STATE_KEY"
    fi
  fi
done

log "Done. Reviewed: $REVIEWED | Skipped: $SKIPPED | Unknown stack: $UNKNOWN"
