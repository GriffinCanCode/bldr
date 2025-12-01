# Builder Notification Plugin

Smart build notifications with context-aware messaging for Slack, Discord, and email.

## Features

- **Multi-Platform**: Slack, Discord, email support
- **Smart Filtering**: Only notify on failures or long builds
- **Rich Context**: Include branch, commit, duration, artifacts
- **Configurable**: Environment-based configuration
- **Zero Dependencies**: Uses only Python standard library

## Install

```bash
cp builder-plugin-notify /usr/local/bin/
chmod +x /usr/local/bin/builder-plugin-notify
# Or via Homebrew:
brew install builder-plugin-notify
```

## Configuration

Set environment variables:

```bash
# Slack
export BUILDER_SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

# Discord
export BUILDER_DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR/WEBHOOK/URL"

# Email (optional)
export BUILDER_SMTP_SERVER="smtp.gmail.com:587"
export BUILDER_EMAIL_TO="team@example.com"

# Notification preferences
export BUILDER_NOTIFY_SUCCESS="false"        # Only notify on failures
export BUILDER_NOTIFY_FAILURE="true"         # Always notify on failures
export BUILDER_NOTIFY_THRESHOLD_MS="5000"    # Only notify if build > 5s
```

## Slack Setup

1. Go to https://api.slack.com/apps
2. Create a new app or select existing
3. Enable "Incoming Webhooks"
4. Add webhook to workspace
5. Copy webhook URL to `BUILDER_SLACK_WEBHOOK`

## Discord Setup

1. Open Discord server settings
2. Go to Integrations → Webhooks
3. Click "New Webhook"
4. Copy webhook URL to `BUILDER_DISCORD_WEBHOOK`

## Message Format

Notifications include:

- **Target name**: The build target
- **Status**: Success/Failure with emoji
- **Duration**: Build time in seconds
- **Branch**: Current git branch
- **Commit**: Short commit hash
- **User**: Who triggered the build
- **Artifacts**: Number of output files

## Examples

### Notify only on failures

```bash
export BUILDER_NOTIFY_SUCCESS="false"
export BUILDER_NOTIFY_FAILURE="true"
```

### Notify on all builds

```bash
export BUILDER_NOTIFY_SUCCESS="true"
export BUILDER_NOTIFY_FAILURE="true"
```

### Notify only on slow builds

```bash
export BUILDER_NOTIFY_THRESHOLD_MS="30000"  # 30 seconds
```

## CI/CD Integration

### GitHub Actions

```yaml
- name: Build with notifications
  env:
    BUILDER_SLACK_WEBHOOK: ${{ secrets.SLACK_WEBHOOK }}
    BUILDER_GIT_BRANCH: ${{ github.ref_name }}
    BUILDER_GIT_COMMIT: ${{ github.sha }}
    BUILDER_USER: ${{ github.actor }}
  run: bldr build //app:main
```

### GitLab CI

```yaml
build:
  script:
    - export BUILDER_SLACK_WEBHOOK="${SLACK_WEBHOOK}"
    - export BUILDER_GIT_BRANCH="${CI_COMMIT_REF_NAME}"
    - export BUILDER_GIT_COMMIT="${CI_COMMIT_SHA}"
    - bldr build //app:main
```

## Test

```bash
# Test plugin info
echo '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}' | ./builder-plugin-notify

# Test notification (requires webhook configured)
echo '{"jsonrpc":"2.0","id":1,"method":"build.post_hook","params":{"target":{"name":"//app:test"},"success":false,"duration_ms":3000,"outputs":[]}}' | ./builder-plugin-notify
```

## License

MIT

