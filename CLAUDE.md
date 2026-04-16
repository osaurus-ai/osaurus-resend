# Osaurus Resend - Osaurus Plugin

This is an Osaurus plugin project. Use this guide to develop, test, and submit the plugin.

## Project Structure

```
osaurus-resend/
├── Package.swift              # Swift Package Manager configuration
├── Sources/
│   └── osaurus_resend/
│       └── Plugin.swift       # Main plugin implementation
├── web/                       # Static frontend assets (v2)
│   └── index.html
├── README.md                  # User-facing documentation
├── CLAUDE.md                  # This file (AI guidance)
└── .github/
    └── workflows/
        └── release.yml        # CI/CD for releases
```

## Architecture Overview

Osaurus plugins use a C ABI interface (v2). The plugin exports `osaurus_plugin_entry_v2(host)` which receives
host callbacks and returns a function table. A v1 fallback (`osaurus_plugin_entry`) is also exported for
compatibility with older Osaurus versions.

**Plugin API (returned to host):**
- `init()` - Initialize plugin, return context pointer
- `destroy(ctx)` - Clean up resources
- `get_manifest(ctx)` - Return JSON describing plugin capabilities
- `invoke(ctx, type, id, payload)` - Execute a tool with JSON payload
- `handle_route(ctx, request_json)` - Handle HTTP route requests (v2)
- `on_config_changed(ctx, key, value)` - React to config changes (v2)
- `on_task_event(ctx, task_id, event_type, event_json)` - Task lifecycle events (v2)
- `free_string(s)` - Free strings returned to host
- `version` - Set to `2` for v2 plugins

**Host API (provided to plugin at init):**
- **Config**: `config_get(key)` / `config_set(key, value)` / `config_delete(key)` - Keychain-backed config
- **Database**: `db_exec(sql, params_json)` / `db_query(sql, params_json)` - Per-plugin SQLite
- **Logging**: `log(level, message)` - Structured logging (visible in Insights tab)
- **Agent Dispatch**: `dispatch(request_json)` / `task_status(task_id)` / `dispatch_cancel(task_id)` / `dispatch_clarify(task_id, response)` - Background agent tasks
- **Inference**: `complete(request_json)` / `complete_stream(request_json, on_chunk, user_data)` / `embed(request_json)` / `list_models()` - LLM inference
- **HTTP Client**: `http_request(request_json)` - Outbound HTTP with SSRF protection

## Adding HTTP Routes

v2 plugins can handle HTTP requests at `/plugins/<plugin_id>/<subpath>`.

### Step 1: Declare Routes in Manifest

Add routes to `capabilities.routes` in `get_manifest()`:

```json
"routes": [
  {
    "id": "webhook",
    "path": "/events",
    "methods": ["POST"],
    "description": "Incoming webhook handler",
    "auth": "verify"
  },
  {
    "id": "app",
    "path": "/app/*",
    "methods": ["GET"],
    "description": "Web UI",
    "auth": "owner"
  }
]
```

Route auth levels: `none` (public), `verify` (rate-limited), `owner` (requires logged-in user).

### Step 2: Handle in handle_route()

The host calls `handle_route(ctx, request_json)` with a JSON-encoded request containing
`route_id`, `method`, `path`, `query`, `headers`, `body`, and `plugin_id`.

Return a JSON-encoded response with `status`, `headers`, and `body`.

## Using Host Storage

v2 plugins receive host callbacks for persistent storage:

```swift
// Read config (Keychain-backed)
if let getValue = hostAPI?.pointee.config_get {
    let result = getValue(makeCString("my_setting"))
    // result is a C string or nil
}

// Write config
if let setValue = hostAPI?.pointee.config_set {
    setValue(makeCString("my_setting"), makeCString("value"))
}

// Query per-plugin SQLite database
if let dbQuery = hostAPI?.pointee.db_query {
    let result = dbQuery(makeCString("SELECT * FROM items"), makeCString("[]"))
    // result is JSON string
}

// Structured logging
if let log = hostAPI?.pointee.log {
    log(0, makeCString("Plugin initialized"))  // 0=debug, 1=info, 2=warn, 3=error
}
```

## Agent Dispatch

v2 plugins can dispatch background agent tasks and monitor their lifecycle:

```swift
// Dispatch a background task
if let dispatch = hostAPI?.pointee.dispatch {
    let request = #"{"prompt":"Summarize the latest news","title":"News Summary"}"#
    let result = dispatch(makeCString(request))
    // result is JSON: {"id":"<task-uuid>","status":"running"}
    if let result { defer { api.free_string?(result) } }
}

// Poll task status
if let taskStatus = hostAPI?.pointee.task_status {
    let status = taskStatus(makeCString("<task-uuid>"))
    // JSON with status, progress, activity feed, clarification state
    if let status { defer { api.free_string?(status) } }
}

// Cancel a task
hostAPI?.pointee.dispatch_cancel?(makeCString("<task-uuid>"))

// Submit clarification response
hostAPI?.pointee.dispatch_clarify?(makeCString("<task-uuid>"), makeCString("Yes, proceed"))
```

Rate limit: 10 dispatches per minute per plugin.

## Inference

v2 plugins can use the host's unified inference layer for chat completions, streaming, embeddings, and model listing:

```swift
// Synchronous chat completion (OpenAI-compatible format)
if let complete = hostAPI?.pointee.complete {
    let request = #"{"model":"","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}"#
    let response = complete(makeCString(request))
    // response is full completion JSON
    if let response { defer { api.free_string?(response) } }
}

// Generate embeddings
if let embed = hostAPI?.pointee.embed {
    let request = #"{"model":"","input":"Hello world"}"#
    let response = embed(makeCString(request))
    if let response { defer { api.free_string?(response) } }
}

// List available models
if let listModels = hostAPI?.pointee.list_models {
    let models = listModels()
    // JSON with "models" array (id, name, provider, context_window, etc.)
    if let models { defer { api.free_string?(models) } }
}
```

Model resolution: pass `""` or `null` for the default model, `"local"` for MLX, `"foundation"` for Apple Foundation Model, or a specific model name.

## HTTP Client

v2 plugins can make outbound HTTP requests through the host (with SSRF protection against private IP ranges):

```swift
if let httpRequest = hostAPI?.pointee.http_request {
    let request = #"{"method":"GET","url":"https://api.example.com/data","headers":{"Authorization":"Bearer token"},"timeout_ms":5000}"#
    let response = httpRequest(makeCString(request))
    // JSON: {"status":200,"headers":{...},"body":"...","elapsed_ms":123}
    if let response { defer { api.free_string?(response) } }
}
```

Request fields: `method`, `url`, `headers`, `body`, `body_encoding`, `timeout_ms`, `follow_redirects`.
Response fields: `status`, `headers`, `body`, `body_encoding`, `elapsed_ms`.

## Task Events

v2 plugins can receive lifecycle events for tasks they dispatch by implementing `on_task_event`:

| Event Type | Value | Payload |
|------------|-------|---------|
| `STARTED` | 0 | `{"status":"running","mode":"...","title":"..."}` |
| `ACTIVITY` | 1 | `{"kind":"...","title":"...","detail":"...","timestamp":"..."}` |
| `PROGRESS` | 2 | `{"progress":0.5,"current_step":"..."}` |
| `CLARIFICATION` | 3 | `{"question":"...","options":[...]}` |
| `COMPLETED` | 4 | `{"success":true,"summary":"...","session_id":"..."}` |
| `FAILED` | 5 | `{"success":false,"summary":"..."}` |
| `CANCELLED` | 6 | `{}` |

```swift
api.on_task_event = { ctxPtr, taskIdPtr, eventType, eventJsonPtr in
    guard let taskIdPtr, let eventJsonPtr else { return }
    let taskId = String(cString: taskIdPtr)
    let eventJson = String(cString: eventJsonPtr)
    
    switch eventType {
    case 4: // COMPLETED
        hostAPI?.pointee.log?(1, makeCString("Task \(taskId) completed: \(eventJson)"))
    case 5: // FAILED
        hostAPI?.pointee.log?(3, makeCString("Task \(taskId) failed: \(eventJson)"))
    default:
        break
    }
}
```

## Adding New Tools

### Step 1: Define the Tool Structure

```swift
private struct MyTool {
    let name = "my_tool"  // Must match manifest id
    let description = "What this tool does"
    
    struct Args: Decodable {
        let inputParam: String
        let optionalParam: String?
    }
    
    func run(args: String) -> String {
        // 1. Parse JSON input
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data) else {
            return "{\"error\": \"Invalid arguments\"}"
        }
        
        // 2. Execute tool logic
        let result = processInput(input.inputParam)
        
        // 3. Return JSON response
        return "{\"result\": \"\(result)\"}"
    }
}
```

### Step 2: Add Tool to PluginContext

```swift
private class PluginContext {
    let helloTool = HelloTool()
    let myTool = MyTool()  // Add your new tool
}
```

### Step 3: Register in Manifest

Add the tool to the `capabilities.tools` array in `get_manifest()`:

```json
{
  "id": "my_tool",
  "description": "What this tool does (shown to users)",
  "parameters": {
    "type": "object",
    "properties": {
      "inputParam": {
        "type": "string",
        "description": "Description of this parameter"
      },
      "optionalParam": {
        "type": "string",
        "description": "Optional parameter"
      }
    },
    "required": ["inputParam"]
  },
  "requirements": [],
  "permission_policy": "ask"
}
```

### Step 4: Handle in invoke()

```swift
api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    // ... existing code ...
    
    if type == "tool" {
        switch id {
        case ctx.helloTool.name:
            return makeCString(ctx.helloTool.run(args: payload))
        case ctx.myTool.name:
            return makeCString(ctx.myTool.run(args: payload))
        default:
            return makeCString("{\"error\": \"Unknown tool\"}")
        }
    }
    
    return makeCString("{\"error\": \"Unknown capability\"}")
}
```

## Using Secrets (API Keys)

If your plugin needs API keys or other credentials, declare them in the manifest and access them via the `_secrets` key in the payload.

### Step 1: Declare Secrets in Manifest

Add a `secrets` array at the top level of your manifest:

```json
{
  "plugin_id": "dev.example.osaurus-resend",
  "name": "Osaurus Resend",
  "version": "0.1.0",
  "secrets": [
    {
      "id": "api_key",
      "label": "API Key",
      "description": "Get your key from [Example](https://example.com/api)",
      "required": true,
      "url": "https://example.com/api"
    }
  ],
  "capabilities": { ... }
}
```

### Step 2: Access Secrets in Your Tool

```swift
private struct MyAPITool {
    let name = "call_api"
    
    struct Args: Decodable {
        let query: String
        let _secrets: [String: String]?  // Secrets injected by Osaurus
    }
    
    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments\"}"
        }
        
        // Get the API key
        guard let apiKey = input._secrets?["api_key"] else {
            return "{\"error\": \"API key not configured\"}"
        }
        
        // Use the API key in your request
        let result = makeAPICall(apiKey: apiKey, query: input.query)
        return "{\"result\": \"\(result)\"}"
    }
}
```

### Secret Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique key (e.g., "api_key") |
| `label` | string | Yes | Display name in UI |
| `description` | string | No | Help text (supports markdown links) |
| `required` | boolean | Yes | Whether the secret is required |
| `url` | string | No | Link to get the secret |

### User Experience

- Users are prompted to configure secrets when installing plugins that require them
- A "Needs API Key" badge appears if required secrets are missing
- Users can edit secrets anytime via the plugin menu
- Secrets are stored securely in the macOS Keychain

## Using Folder Context (Working Directory)

When a user has a working directory selected in Work Mode, Osaurus automatically injects the folder context into tool payloads. This allows your plugin to resolve relative file paths.

### Automatic Injection

When a folder context is active, every tool invocation receives a `_context` object:

```json
{
  "input_path": "Screenshots/image.png",
  "_context": {
    "working_directory": "/Users/foo/project"
  }
}
```

### Accessing Folder Context in Your Tool

```swift
private struct MyFileTool {
    let name = "process_file"
    
    struct FolderContext: Decodable {
        let working_directory: String
    }
    
    struct Args: Decodable {
        let path: String
        let _context: FolderContext?  // Folder context injected by Osaurus
    }
    
    func run(args: String) -> String {
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments\"}"
        }
        
        // Resolve relative path using working directory
        let absolutePath: String
        if let workingDir = input._context?.working_directory {
            absolutePath = "\(workingDir)/\(input.path)"
        } else {
            // No folder context - assume absolute path or return error
            absolutePath = input.path
        }
        
        // SECURITY: Validate path stays within working directory
        if let workingDir = input._context?.working_directory {
            let resolvedPath = URL(fileURLWithPath: absolutePath).standardized.path
            guard resolvedPath.hasPrefix(workingDir) else {
                return "{\"error\": \"Path outside working directory\"}"
            }
        }
        
        // Process the file at absolutePath...
        return "{\"success\": true}"
    }
}
```

### Security Considerations

- **Always validate paths** stay within `working_directory` to prevent directory traversal
- The LLM is instructed to use relative paths for file operations
- Reject paths that attempt to escape (e.g., `../../../etc/passwd`)
- If `_context` is absent, decide whether to require it or accept absolute paths

### Context Fields

| Field | Type | Description |
|-------|------|-------------|
| `working_directory` | string | Absolute path to the user's selected folder |

## Porting Existing Tools

### From MCP (Model Context Protocol)

MCP tools map directly to Osaurus tools:

| MCP Concept | Osaurus Equivalent |
|-------------|-------------------|
| Tool name | `id` in manifest |
| Input schema | `parameters` (JSON Schema) |
| Tool handler | `run()` method in tool struct |
| Response | JSON string return value |

Example MCP tool conversion:
```json
// MCP tool definition
{
  "name": "get_weather",
  "description": "Get weather for a location",
  "inputSchema": {
    "type": "object",
    "properties": {
      "location": { "type": "string" }
    },
    "required": ["location"]
  }
}
```

Becomes this Osaurus manifest entry:
```json
{
  "id": "get_weather",
  "description": "Get weather for a location",
  "parameters": {
    "type": "object",
    "properties": {
      "location": { "type": "string" }
    },
    "required": ["location"]
  },
  "requirements": [],
  "permission_policy": "ask"
}
```

### From CLI Tools

Wrap command-line tools using Process/subprocess:

```swift
func run(args: String) -> String {
    guard let input = parseArgs(args) else {
        return "{\"error\": \"Invalid arguments\"}"
    }
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/some-cli")
    process.arguments = [input.flag, input.value]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        if process.terminationStatus == 0 {
            return "{\"output\": \"\(output.escapedForJSON)\"}"
        } else {
            return "{\"error\": \"Command failed: \(output.escapedForJSON)\"}"
        }
    } catch {
        return "{\"error\": \"\(error.localizedDescription)\"}"
    }
}
```

### From Web APIs

Use `host.http_request` to make outbound HTTP calls (preferred over native HTTP libraries):

```swift
func run(args: String) -> String {
    guard let input = parseArgs(args) else {
        return "{\"error\": \"Invalid arguments\"}"
    }
    
    guard let httpRequest = hostAPI?.pointee.http_request else {
        return "{\"error\": \"HTTP client not available\"}"
    }
    
    let body = (try? JSONEncoder().encode(input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let request = "{\"method\":\"POST\",\"url\":\"https://api.example.com/endpoint\",\"headers\":{\"Content-Type\":\"application/json\"},\"body\":\"\(body.replacingOccurrences(of: "\"", with: "\\\""))\",\"timeout_ms\":10000}"
    let response = httpRequest(makeCString(request))
    guard let response else { return "{\"error\": \"Request failed\"}" }
    defer { api.free_string?(response) }
    return String(cString: response)
}
```

## Testing Workflow

### 1. Start Dev Mode

From the project root, run:

```bash
osaurus tools dev
```

This builds the plugin, installs it into Osaurus, and watches for source changes.
Any edits to source files trigger an automatic rebuild and hot-reload.

### 2. Test in Osaurus

1. Open Osaurus app
2. Go to Tools settings (Cmd+Shift+M → Tools)
3. Verify your plugin appears
4. Test each tool by asking the AI to use it

### 3. Iterate

Edit source files and save. `osaurus tools dev` automatically rebuilds and reloads.

## Best Practices

### JSON Schema for Parameters

- Always specify `type` for each property
- Use `description` to help the AI understand parameter purpose
- Mark truly required fields in `required` array
- Use appropriate types: `string`, `number`, `integer`, `boolean`, `array`, `object`

```json
{
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "Search query text"
    },
    "limit": {
      "type": "integer",
      "description": "Maximum results to return",
      "default": 10
    },
    "filters": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Optional filter tags"
    }
  },
  "required": ["query"]
}
```

### Error Handling

Always return valid JSON, even for errors:

```json
{"error": "Clear description of what went wrong"}
```

For detailed errors:
```json
{"error": "Validation failed", "details": {"field": "query", "message": "Cannot be empty"}}
```

### Tool Naming

- Use `snake_case` for tool IDs: `get_weather`, `search_files`
- Be descriptive but concise
- Prefix related tools: `github_create_issue`, `github_list_repos`

### Permission Policies

| Policy | When to Use |
|--------|-------------|
| `ask` | Default. User confirms each execution |
| `auto` | Safe, read-only operations |
| `deny` | Dangerous operations (use sparingly) |

### System Requirements

Add to `requirements` array when your tool needs:

| Requirement | Use Case |
|-------------|----------|
| `automation` | AppleScript, controlling other apps |
| `accessibility` | UI automation, input simulation |
| `calendar` | Reading/writing calendar events |
| `contacts` | Accessing contact information |
| `location` | Getting user's location |
| `disk` | Full disk access (Messages, Safari data) |
| `reminders` | Reading/writing reminders |
| `notes` | Accessing Notes app |
| `maps` | Controlling Maps app |

## Submission Checklist

Before submitting to the Osaurus plugin registry:

- [ ] Plugin builds without warnings
- [ ] `osaurus manifest extract` returns valid JSON
- [ ] All tools have clear descriptions
- [ ] Parameters use proper JSON Schema
- [ ] Error cases return valid JSON errors
- [ ] Version follows semver (X.Y.Z)
- [ ] plugin_id follows reverse-domain format (com.yourname.pluginname)
- [ ] README.md documents all tools
- [ ] Code is signed with Developer ID (for distribution)

### Code Signing (Required for Distribution)

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  .build/release/libosaurus-resend.dylib
```

### Registry Submission

1. Fork the [osaurus-tools](https://github.com/osaurus-ai/osaurus-tools) repository
2. Add `plugins/<your-plugin-id>.json` with metadata
3. Submit a pull request

## Common Issues

### Plugin not loading

- Check `osaurus manifest extract` for errors
- Verify the dylib is properly signed
- Check Console.app for loading errors

### Tool not appearing

- Ensure tool is in manifest `capabilities.tools` array
- Verify `invoke()` handles the tool ID
- Check tool ID matches exactly (case-sensitive)

### JSON parsing errors

- Validate JSON escaping in strings
- Use proper encoding for special characters
- Test with `echo '{"param":"value"}' | osaurus manifest extract ...`