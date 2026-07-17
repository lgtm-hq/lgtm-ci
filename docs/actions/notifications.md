# Notification actions

Webhook notifications for CI/CD events with consistent formatting across
repositories. Both actions share the same interface (`status`, `title`,
`message`, `fields`, `webhook-url`, `dry-run`), auto-inject workflow
context (repository, run URL, ref, actor), and deliver with `curl` only —
transient failures (timeouts, HTTP 429, HTTP 5xx) are retried with
backoff, while hard rejections fail immediately.

Set `dry-run: "true"` to print the JSON payload instead of POSTing it
(useful in CI where no real webhook should be hit). Both actions expose a
`delivered` output (`"true"`/`"false"`; always `"false"` in dry-run).

The `fields` input is a newline-separated `KEY=VALUE` list (simple YAML
`KEY: VALUE` lines also work); blank lines and `#` comments are ignored.

## notify-slack

Send a Slack notification via incoming webhook using Block Kit: a header
with a status emoji, an optional message section, your extra fields, and
a context line linking to the workflow run. The attachment color tracks
`status` (green success, red failure, yellow cancelled).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/notify-slack@<commit-sha> # pin to a full commit SHA
  if: failure()
  with:
    webhook-url: ${{ secrets.SLACK_WEBHOOK }}
    status: failure
    title: "Build Failed"
    message: "Build failed on ${{ github.ref_name }}"
    fields: |
      Environment=production
      Version=1.2.3
```

**Inputs:** `webhook-url` (required), `title` (required), `status`
(`success` | `failure` | `cancelled`, default `success`), `message`
(Slack mrkdwn), `fields`, `dry-run`.

**Outputs:** `delivered`.

## notify-discord

Send a Discord notification via webhook using an embed: emoji-prefixed
title linking to the workflow run, optional description, your extra
fields, and injected `Repository`/`Ref`/`Actor` fields. The embed color
tracks `status`.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/notify-discord@<commit-sha> # pin to a full commit SHA
  with:
    webhook-url: ${{ secrets.DISCORD_WEBHOOK }}
    status: success
    title: "Deployment Complete"
    fields: |
      Environment: production
```

**Inputs:** `webhook-url` (required), `title` (required), `status`
(`success` | `failure` | `cancelled`, default `success`), `message`
(embed description), `fields`, `dry-run`.

**Outputs:** `delivered`.

## Retry and delivery behavior

Delivery POSTs the JSON payload with `curl` (10s connect timeout, 30s
total). The webhook URL is passed via a curl config file on stdin, not
as a CLI argument, so it is not visible in the process table on shared
runners. Up to 3 attempts are made; retries apply only to transport
errors, HTTP 429, and HTTP 5xx, with a linear backoff (2s, 4s). On HTTP
429 the `Retry-After` header (or Discord's JSON `retry_after` body) is
honored when present, capped at 30s. Other non-2xx responses (bad
webhook URL, malformed payload) fail immediately. Webhook URLs must use
`https://`. Advanced tuning is available via environment variables
(`NOTIFY_MAX_ATTEMPTS`, `NOTIFY_RETRY_BACKOFF`, `NOTIFY_RETRY_MAX_DELAY`,
`NOTIFY_CONNECT_TIMEOUT`, `NOTIFY_MAX_TIME`).

Field limits: Slack section blocks hold at most 10 fields, so custom
fields are chunked across additional section blocks automatically.
Discord embeds cap at 25 fields; with 3 auto-injected context fields,
more than 22 custom fields is rejected with an error.
