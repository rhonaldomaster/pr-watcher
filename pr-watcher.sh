#!/usr/bin/env bash
set -euo pipefail

SKILLS_DIR="/Users/rhonalf.martinez/projects/claude-skills/pr-cycle/skills"
STATE_FILE="/Users/rhonalf.martinez/projects/claude-skills/pr-watcher-state.json"
LOG_FILE="/Users/rhonalf.martinez/.claude/logs/pr-watcher.log"
CLAUDE_BIN="/Users/rhonalf.martinez/.local/bin/claude"
GH_BIN="/opt/homebrew/bin/gh"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Work hours check: Mon-Fri, 8am-7pm COT (UTC-5)
HOUR=$(TZ="America/Bogota" date +%H)
DOW=$(TZ="America/Bogota" date +%u)  # 1=Mon 7=Sun
if [[ "$DOW" -gt 5 || "$HOUR" -lt 8 || "$HOUR" -ge 19 ]]; then
  log "Outside work hours, skipping."
  exit 0
fi

log "Starting PR watcher run."

# Load state
if [[ -f "$STATE_FILE" ]]; then
  STATE=$(cat "$STATE_FILE")
else
  STATE='{"reviewed":{}}'
fi

# Fetch PRs where review is requested (use API directly — avoids needing a git repo context)
PRS=$("$GH_BIN" api graphql -f query='
{
  search(query: "is:pr is:open review-requested:rhonaldomaster", type: ISSUE, first: 50) {
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
}' --jq '.data.search.nodes' 2>/dev/null || echo "[]")

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
  PR=$(echo "$PRS" | jq ".[$i]")
  PR_NUMBER=$(echo "$PR" | jq -r '.number')
  PR_TITLE=$(echo "$PR" | jq -r '.title')
  CURRENT_SHA=$(echo "$PR" | jq -r '.headRefOid')
  REPO_OWNER=$(echo "$PR" | jq -r '.headRepository.nameWithOwner' | cut -d'/' -f1)
  REPO_NAME=$(echo "$PR" | jq -r '.headRepository.nameWithOwner' | cut -d'/' -f2)
  STATE_KEY="$REPO_OWNER/$REPO_NAME#$PR_NUMBER"

  log "Checking $STATE_KEY (SHA: ${CURRENT_SHA:0:8})"

  # Check if already reviewed at this SHA
  LAST_SHA=$(echo "$STATE" | jq -r --arg key "$STATE_KEY" '.reviewed[$key] // ""')
  if [[ "$LAST_SHA" == "$CURRENT_SHA" ]]; then
    log "SKIPPED: $STATE_KEY — already reviewed at current SHA"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Clone repo to detect type
  TMP_DIR=$(mktemp -d)
  trap "rm -rf $TMP_DIR" EXIT

  log "Cloning $REPO_OWNER/$REPO_NAME to detect stack..."
  "$GH_BIN" repo clone "$REPO_OWNER/$REPO_NAME" "$TMP_DIR" -- --depth=1 --quiet 2>/dev/null || {
    log "ERROR: Could not clone $REPO_OWNER/$REPO_NAME — skipping"
    UNKNOWN=$((UNKNOWN + 1))
    continue
  }

  cd "$TMP_DIR"
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

  cd - > /dev/null

  if [[ -z "$SKILL" ]]; then
    log "UNKNOWN stack for $STATE_KEY — sending notification"
    "$CLAUDE_BIN" --dangerously-skip-permissions -p \
      "Send a push notification with this exact message: PR #$PR_NUMBER en $REPO_NAME — stack desconocido, revision manual requerida" \
      2>/dev/null || true
    UNKNOWN=$((UNKNOWN + 1))
    continue
  fi

  SKILL_FILE="$SKILLS_DIR/$SKILL/SKILL.md"
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

  "$CLAUDE_BIN" --dangerously-skip-permissions -p "$PROMPT" \
    --allowedTools "Bash,Read,Glob,Grep,Agent" \
    2>>"$LOG_FILE" || {
    log "ERROR: claude failed for $STATE_KEY"
    continue
  }

  # Update state
  STATE=$(echo "$STATE" | jq --arg key "$STATE_KEY" --arg sha "$CURRENT_SHA" '.reviewed[$key] = $sha')
  echo "$STATE" > "$STATE_FILE"

  # Commit state update
  cd /Users/rhonalf.martinez/projects/claude-skills
  git add pr-watcher-state.json
  git diff --staged --quiet || git commit -m "chore: pr-watcher state [$STATE_KEY]" 2>/dev/null || true
  git push 2>/dev/null || true
  cd - > /dev/null

  log "REVIEWED: $STATE_KEY with skill $SKILL"
  REVIEWED=$((REVIEWED + 1))
done

log "Done. Reviewed: $REVIEWED | Skipped: $SKIPPED | Unknown stack: $UNKNOWN"
