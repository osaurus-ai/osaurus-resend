# Osaurus Resend (Email)

Send, receive, and manage email through [Resend](https://resend.com). Agents can handle inbound emails as full async tasks, reply with proper threading, organize conversations with labels, and attach file artifacts automatically.

## Features

### Inbound Email

All incoming emails are dispatched as full agent tasks with tool access, sandbox, and the complete agent runtime. This is designed for real async work -- scheduling, invoice processing, multi-step workflows -- not lightweight chat.

- **Webhook-based receiving** -- Resend forwards inbound emails to the plugin via webhook
- **Full email body retrieval** -- the plugin fetches complete email content including HTML and plain text
- **Thread continuity** -- replies are matched to existing threads via `In-Reply-To` headers
- **Thread history** -- the agent receives the full conversation context when processing a new email

### Outbound Email

- **Reply-all by default** -- `resend_reply` automatically derives recipients from thread participants
- **Proper threading** -- all replies include `In-Reply-To` and `References` headers
- **Artifact attachments** -- files produced during agent tasks are automatically attached to reply emails
- **New conversations** -- `resend_send` composes new emails and creates new threads

### Authorization

Sender authorization is derived from the data model itself -- no separate auth system:

- **Known senders** (default) -- only accepts emails from addresses in `allowed_senders` config, recipients the agent has previously emailed, or participants in existing threads
- **Open mode** -- accepts all inbound emails (for support inboxes or public-facing agents)
- **Thread-based auth** -- when the agent emails someone (e.g., to schedule a meeting), that person can reply without needing to be on the allowlist

### Labels

Threads can be tagged with freeform labels for organization. The agent manages labels through the `resend_label_thread` tool and can filter threads by label using `resend_list_threads`.

## Tools

| Tool | Description |
|------|-------------|
| `resend_send` | Compose and send a new email. Creates a thread and authorizes the recipient. |
| `resend_reply` | Reply to an existing thread. Reply-all by default with proper threading headers. |
| `resend_list_threads` | List threads, optionally filtered by participant or label. |
| `resend_get_thread` | Get full thread detail with all message bodies. |
| `resend_label_thread` | Add or remove labels on a thread. |

## Routes

| Route | Method | Auth | Description |
|-------|--------|------|-------------|
| /webhook | POST | verify | Resend webhook endpoint for inbound emails |
| /health | GET | owner | Health check with webhook registration status |

## Configuration

| Key | Type | Description |
|-----|------|-------------|
| `api_key` | secret | Resend API key from [resend.com/api-keys](https://resend.com/api-keys) |
| `from_email` | text | Sender email address (must be a verified domain in Resend) |
| `from_name` | text | Display name for outgoing emails |
| `sender_policy` | select | `known` (default) or `open` |
| `allowed_senders` | text | Comma-separated email addresses or @domains |

## Setup

### 1. Get a Resend API Key

1. Create an account at [resend.com](https://resend.com)
2. Add and verify your sending domain
3. Create an API key at [resend.com/api-keys](https://resend.com/api-keys)

### 2. Set Up Email Receiving

1. Go to [Resend Receiving](https://resend.com/emails/receiving) to get your receiving domain
2. For custom domains, add the MX record as described in Resend's docs

### 3. Configure the Plugin

1. Open Osaurus and go to your Agent settings
2. Find the Resend plugin and enter your API key
3. Set your `from_email` to a verified address on your Resend domain
4. Add your own email to `allowed_senders` so you can email the agent
5. The plugin will automatically register a webhook with Resend

### 4. Start Emailing

Send an email to your Resend receiving address. The agent will process it and reply.

## Example Workflows

### Calendar Scheduling

You CC the agent on an email to a colleague. The colleague replies with available times. The agent checks your calendar, creates an event, and replies-all with the confirmation.

### Invoice Processing

Vendors email the agent with invoices. The agent processes them, updates your accounting system, and replies with a confirmation.

### Scheduled Outreach

The agent sends invoice reminders to contractors on a schedule. When contractors reply, the agent processes the response and forwards relevant information to your billing team.

## Development

```bash
osaurus tools dev
```

## License

MIT
