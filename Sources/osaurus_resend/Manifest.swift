import Foundation

/// Single source of truth for the plugin version. Embedded in the manifest and
/// used to derive the outbound `User-Agent`. Must match `osaurus-plugin.json`.
let resendPluginVersion = "1.3.1"

/// The plugin manifest, returned verbatim from `get_manifest`. Kept as a
/// file-scope constant (rather than inline in the C-ABI builder closure) so it
/// is a single source of truth that tests can parse directly.
let resendManifestJSON = """
  {
    "plugin_id": "osaurus.resend",
    "name": "Resend (Email)",
    "version": "\(resendPluginVersion)",
    "description": "Send, receive, and manage email through Resend",
    "instructions": "You have access to email via the Resend plugin. This is asynchronous email communication, not instant messaging. Write complete, professional, self-contained responses -- the recipient may not read your reply for hours or days. Every response should be thorough enough to stand on its own without requiring immediate follow-up.\\n\\nWhen you receive an inbound email, the thread_id is provided in the prompt. Use resend_reply with that thread_id to respond. The reply is sent to all thread participants by default (reply-all). If you need to reply only to a specific person, pass the to parameter.\\n\\nTo compose a new email to someone not in the current thread, use resend_send. This creates a new thread and authorizes the recipient for future replies.\\n\\nTo review past conversations, use resend_list_threads (filterable by participant or label) for summaries, and resend_get_thread for full message bodies. Use resend_label_thread to tag threads for organization (e.g. scheduling, invoices, urgent).\\n\\nIf a follow-up email arrives on the same thread while you are still working, the new message is appended to your conversation automatically and you should incorporate it into a single coherent reply rather than answering each email separately. The thread retains its full history across resumes, so feel free to call resend_get_thread when you need to refresh context.\\n\\nIf the email-system reports a send failure (e.g. bounce, suppression), reconsider the recipient and either correct the address, pick a different person, or stop trying to email that destination -- do not retry the same address.\\n\\nWhen producing files during a task, they are automatically attached to your next reply. You do not need to handle attachments manually.",
    "license": "MIT",
    "authors": [],
    "min_macos": "15.0",
    "min_osaurus": "0.18.14",
    "capabilities": {
      "tools": [
        {
          "id": "resend_send",
          "description": "Send a new email to start a new conversation. Use this when you need to email someone who is not part of the current thread (e.g. scheduling with a new contact, forwarding information to another person). Creates a new thread. The recipient will be able to reply back.",
          "parameters": {
            "type": "object",
            "properties": {
              "to": { "type": "string", "description": "Recipient email address" },
              "subject": { "type": "string", "description": "Email subject line" },
              "body": { "type": "string", "description": "Email body content. HTML is supported for formatting." },
              "cc": { "type": "string", "description": "CC recipient email address (optional)" },
              "bcc": { "type": "string", "description": "BCC recipient email address (optional)" }
            },
            "required": ["to", "subject", "body"]
          },
          "requirements": [],
          "permission_policy": "auto"
        },
        {
          "id": "resend_reply",
          "description": "Reply to an email in an existing thread. Sends to all thread participants by default (reply-all). Use the optional 'to' parameter to reply to only one specific person. Threading headers are handled automatically so the reply appears in the same conversation in the recipient's inbox. Any files produced during the current task are attached automatically.",
          "parameters": {
            "type": "object",
            "properties": {
              "thread_id": { "type": "string", "description": "The thread ID to reply in (provided in the inbound email prompt)" },
              "body": { "type": "string", "description": "Reply body content. HTML is supported for formatting." },
              "to": { "type": "string", "description": "Send to only this address instead of all participants (optional)" }
            },
            "required": ["thread_id", "body"]
          },
          "requirements": [],
          "permission_policy": "auto"
        },
        {
          "id": "resend_list_threads",
          "widget": true,
          "description": "List email conversation threads. Returns thread summaries (subject, participants, labels, last message preview). Use this to find threads by participant email or label, or to see recent conversations. For full message content, follow up with resend_get_thread.",
          "parameters": {
            "type": "object",
            "properties": {
              "participant": { "type": "string", "description": "Filter to threads involving this email address" },
              "label": { "type": "string", "description": "Filter to threads with this label (e.g. 'invoices', 'scheduling')" },
              "limit": { "type": "integer", "description": "Max threads to return (default 20, max 100)" }
            },
            "required": []
          },
          "requirements": [],
          "permission_policy": "auto"
        },
        {
          "id": "resend_get_thread",
          "description": "Get the full details of a specific email thread, including complete message bodies in chronological order. Use this to read the full conversation, quote a previous message, or gather context before replying.",
          "parameters": {
            "type": "object",
            "properties": {
              "thread_id": { "type": "string", "description": "Thread ID to retrieve" },
              "limit": { "type": "integer", "description": "Max messages to return (default 20, max 200)" }
            },
            "required": ["thread_id"]
          },
          "requirements": [],
          "permission_policy": "auto"
        },
        {
          "id": "resend_label_thread",
          "description": "Add or remove labels on a thread to organize conversations. Labels are freeform strings -- use whatever makes sense for the context (e.g. scheduling, invoices, urgent, follow-up). Threads can be filtered by label using resend_list_threads.",
          "parameters": {
            "type": "object",
            "properties": {
              "thread_id": { "type": "string", "description": "Thread ID to update labels on" },
              "add": {
                "type": "array",
                "items": { "type": "string" },
                "description": "Labels to add to the thread"
              },
              "remove": {
                "type": "array",
                "items": { "type": "string" },
                "description": "Labels to remove from the thread"
              }
            },
            "required": ["thread_id"]
          },
          "requirements": [],
          "permission_policy": "auto"
        }
      ],
      "artifact_handler": true,
      "routes": [
        {
          "id": "webhook",
          "path": "/webhook",
          "methods": ["POST"],
          "description": "Resend webhook endpoint for inbound emails",
          "auth": "verify"
        },
        {
          "id": "health",
          "path": "/health",
          "methods": ["GET"],
          "description": "Health check",
          "auth": "owner"
        },
        {
          "id": "reset_webhook",
          "path": "/reset_webhook",
          "methods": ["POST"],
          "description": "Wipe all plugin webhooks on the Resend account and re-register a single fresh webhook with the current tunnel URL.",
          "auth": "owner"
        }
      ],
      "config": {
        "title": "Resend (Email)",
        "sections": [
          {
            "title": "Resend Configuration",
            "fields": [
              {
                "key": "api_key",
                "type": "secret",
                "label": "API Key",
                "placeholder": "re_xxxxxxxxx",
                "description": "Get your API key from [Resend](https://resend.com/api-keys)",
                "validation": { "required": true }
              },
              {
                "key": "from_email",
                "type": "text",
                "label": "From Email",
                "placeholder": "agent@yourdomain.com",
                "description": "Sender email address (must be a verified domain in Resend)",
                "validation": { "required": true }
              },
              {
                "key": "from_name",
                "type": "text",
                "label": "From Name",
                "placeholder": "Agent",
                "description": "Display name for outgoing emails"
              }
            ]
          },
          {
            "title": "Webhook",
            "fields": [
              {
                "key": "webhook_url",
                "type": "readonly",
                "label": "Webhook URL",
                "value_template": "{{plugin_url}}/webhook",
                "copyable": true
              },
              {
                "key": "webhook_status",
                "type": "status",
                "label": "Webhook",
                "connected_when": "webhook_registered"
              }
            ]
          },
          {
            "title": "Authorization",
            "fields": [
              {
                "key": "sender_policy",
                "type": "select",
                "label": "Sender Policy",
                "description": "Controls who can email the agent. 'known' only accepts emails from allowed senders and existing thread participants. 'open' accepts all emails.",
                "default": "known",
                "options": [
                  { "value": "known", "label": "Known senders only" },
                  { "value": "open", "label": "Accept all emails" }
                ]
              },
              {
                "key": "allowed_senders",
                "type": "text",
                "label": "Allowed Senders",
                "placeholder": "alice@gmail.com, @company.com",
                "description": "Comma-separated email addresses or @domains. These senders are always authorized."
              }
            ]
          }
        ]
      }
    },
    "docs": {
      "readme": "README.md",
      "links": [
        { "label": "Resend Docs", "url": "https://resend.com/docs" },
        { "label": "Resend API", "url": "https://resend.com/docs/api-reference/introduction" }
      ]
    }
  }
  """
