# PR Watcher

A local macOS agent that monitors GitHub for pull requests where your review is requested, automatically runs a code review using the appropriate skill, and sends a push notification when done.

## How it works

1. Runs every 30 minutes during work hours (Mon–Fri, 8am–7pm COT)
2. Fetches all open PRs where `review-requested:@me` via the GitHub API
3. Skips PRs already reviewed at the current commit SHA (state tracked in `rhonaldomaster/claude-skills/pr-watcher-state.json`)
4. Detects the repo stack and picks the matching review skill:
   - `Gemfile` → Rails
   - `composer.json` + `functions.php` → WordPress
   - `composer.json` → Yii2
   - `*.liquid` files → Shopify
   - `package.json` → Next.js / frontend JS
5. Runs `claude -p` with the full skill inline
6. Posts inline GitHub comments + summary review
7. Sends a push notification: "PR listo para tu veredicto: [repo] #N — [title]"
8. Stops before approving or moving Jira tickets — those require human sign-off

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/claude-code) installed at `~/.local/bin/claude`
- [GitHub CLI](https://cli.github.com/) (`gh`) authenticated with your account
- `jq` installed (`brew install jq`)
- macOS (uses launchd)
- Review skills in `/Users/rhonalf.martinez/projects/claude-skills/pr-cycle/skills/`

## Setup

1. Copy the script to `~/.claude/scripts/`:
   ```bash
   mkdir -p ~/.claude/scripts
   cp pr-watcher.sh ~/.claude/scripts/pr-watcher.sh
   chmod +x ~/.claude/scripts/pr-watcher.sh
   ```

2. Edit the plist and update `YOUR_USERNAME` to match your macOS username, then install it:
   ```bash
   cp com.rhonalf.pr-watcher.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.rhonalf.pr-watcher.plist
   ```

3. Verify it loaded:
   ```bash
   launchctl list | grep pr-watcher
   ```

## Running manually

```bash
~/.claude/scripts/pr-watcher.sh
```

## Stopping

```bash
# Stop permanently
launchctl unload ~/Library/LaunchAgents/com.rhonalf.pr-watcher.plist

# Stop current run only
launchctl stop com.rhonalf.pr-watcher
```

## Logs

```bash
tail -f ~/.claude/logs/pr-watcher.log
```

## State file

Reviewed PRs and their commit SHAs are tracked in `rhonaldomaster/claude-skills/pr-watcher-state.json`. When a developer pushes new commits, the SHA changes and the watcher re-reviews automatically.
