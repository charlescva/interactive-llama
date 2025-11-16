use anyhow::Result;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::fs;
use std::path::{Component, Path, PathBuf};

/// The root directory the agent is allowed to operate in.
///
/// IMPORTANT: the agent is SANDBOXED to this path; it cannot escape it.
const WORKSPACE_ROOT: &str = "/home/pc2dev/ai_workspace";

/// OpenAI-style chat message.
#[derive(Debug, Serialize)]
struct ChatMessage {
    role: String,
    content: String,
}

/// Tool calls emitted by the model as pure JSON.
#[derive(Debug, Deserialize)]
#[serde(tag = "tool")]
enum ToolCall {
    #[serde(rename = "list_dir")]
    ListDir { path: String },

    #[serde(rename = "read_file")]
    ReadFile { path: String },

    #[serde(rename = "write_file")]
    WriteFile { path: String, content: String },
}

/// Results returned back to the model after executing a tool.
#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "lowercase")]
enum ToolResult {
    Ok { result: serde_json::Value },
    Error { message: String },
}

/// Singleton-style agent struct holding client + chat state.
struct Agent {
    client: Client,
    messages: Vec<ChatMessage>,
}

impl Agent {
    /// Create a new agent with a system prompt that explains the tool protocol.
    fn new(initial_user_task: &str) -> Self {
        let system_prompt = format!(
            "\
You are a Rust coding agent operating inside a local filesystem workspace.

Workspace root (you MUST NOT leave this directory): `{root}`.

You cannot run shell commands or access the real OS directly.
Instead, you use the following TOOLS by emitting **pure JSON** (no surrounding text):

1) List directory contents:
   {{\"tool\": \"list_dir\", \"path\": \"relative/path\"}}

2) Read a file as UTF-8 text:
   {{\"tool\": \"read_file\", \"path\": \"relative/path\"}}

3) Write (create/overwrite) a file with UTF-8 content:
   {{\"tool\": \"write_file\", \"path\": \"relative/path\", \"content\": \"...\"}}

Rules:
- `path` is ALWAYS RELATIVE to the workspace root `{root}`.
- NEVER include `..` in paths.
- When you want to use a tool, respond with ONLY the JSON object, nothing else.
- I (the system) will reply with a tool result in the form:
  TOOL_RESULT: <json>

  where the JSON has the shape:
    {{\"status\":\"ok\",\"result\":{{...}}}} or
    {{\"status\":\"error\",\"message\":\"...\"}}

- After seeing a TOOL_RESULT, you may call another tool (again, with pure JSON),
  or continue with normal reasoning and natural-language explanation.

- When you are FINISHED with the task, respond with a normal natural-language answer,
  describing what you did and showing the important code snippets.

Your main goal:
- Use the tools to inspect and modify files in the workspace
- Create and update Rust source files as requested
- Keep code idiomatic and compilable
",
            root = WORKSPACE_ROOT
        );

        let mut messages = Vec::new();
        messages.push(ChatMessage {
            role: "system".into(),
            content: system_prompt,
        });

        messages.push(ChatMessage {
            role: "user".into(),
            content: initial_user_task.to_string(),
        });

        Agent {
            client: Client::new(),
            messages,
        }
    }

    /// Main loop: calls the LLM, interprets tool calls, executes them, and feeds results back.
    async fn run(&mut self) -> Result<()> {
        loop {
            let reply = self.call_llm().await?;
            println!("\n[LLM raw reply]\n{reply}\n");

            // NEW: try to extract JSON from possible ```json ... ``` markdown
            let json_candidate = extract_json_from_markdown(&reply);

            // Try to parse the reply as a tool call (pure JSON).
            match serde_json::from_str::<ToolCall>(&json_candidate) {
                Ok(tool_call) => {
                    println!("[Agent] Detected tool call: {:?}", tool_call);
                    // Record assistant's tool-call JSON as a message.
                    self.messages.push(ChatMessage {
                        role: "assistant".into(),
                        content: format!("TOOL CALL"),
                    });
                    
                    let result = execute_tool(tool_call);
                    let result_json = serde_json::to_string(&result)?;

                    // Record assistant's tool-call JSON as a message.
                    self.messages.push(ChatMessage {
                        role: "assistant".into(),
                        content: reply,
                    });

                    // Provide tool result back as a new user message.
                    self.messages.push(ChatMessage {
                        role: "user".into(),
                        content: format!("TOOL_RESULT: {result_json}"),
                    });
                    

                    // Loop again, giving the model the tool result.
                    continue;
                }
                Err(_) => {
                    // Not valid ToolCall JSON → treat as final natural-language answer and stop.
                    println!("=== Final assistant answer ===\n{reply}");
                    break;
                }
            }
        }

        Ok(())
    }

    /// Call the local llama-server /v1/chat/completions endpoint.
    async fn call_llm(&self) -> Result<String> {
        let url = "http://127.0.0.1:8080/v1/chat/completions";
        let body = json!({
            "model": "qwen2.5-coder-7b", // must match --alias passed to llama-server
            "messages": self.messages,
            "stream": false
        });

        let resp = self
            .client
            .post(url)
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?;

        let status = resp.status();

        if !status.is_success() {
            // `text()` consumes `resp`, so we store status first and don't use `resp` afterwards.
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("LLM error {}: {}", status, text);
        }

        #[derive(Debug, Deserialize)]
        struct Resp {
            choices: Vec<Choice>,
        }

        #[derive(Debug, Deserialize)]
        struct Choice {
            message: LlmMessage,
        }

        #[derive(Debug, Deserialize)]
        struct LlmMessage {
            content: String,
        }

        let parsed: Resp = resp.json().await?;
        let content = parsed
            .choices
            .get(0)
            .map(|c| c.message.content.clone())
            .unwrap_or_default();

        Ok(content)
    }
}

/// Ensure `rel` is a safe relative path (no `..`).
fn ensure_safe_relative(rel: &str) -> Result<(), String> {
    let p = Path::new(rel);
    for comp in p.components() {
        if let Component::ParentDir = comp {
            return Err(format!(
                "Path must not contain '..' components: {rel}"
            ));
        }
    }
    Ok(())
}

/// Convert a relative path into an absolute path under WORKSPACE_ROOT.
fn resolve_workspace_path(rel: &str) -> Result<PathBuf, String> {
    ensure_safe_relative(rel)?;
    let root = Path::new(WORKSPACE_ROOT);
    Ok(root.join(rel))
}



/// Execute a tool call against the local filesystem, sandboxed to WORKSPACE_ROOT.
fn execute_tool(call: ToolCall) -> ToolResult {
    match call {
        ToolCall::ListDir { path } => {
            match resolve_workspace_path(&path).and_then(|p| {
                let mut entries = Vec::new();
                let read_dir = fs::read_dir(&p)
                    .map_err(|e| format!("read_dir failed on {}: {e}", p.display()))?;
                for entry in read_dir {
                    let entry = entry.map_err(|e| e.to_string())?;
                    let file_type = entry.file_type().map_err(|e| e.to_string())?;
                    entries.push(json!({
                        "name": entry.file_name(),
                        "is_dir": file_type.is_dir(),
                        "is_file": file_type.is_file(),
                    }));
                }
                Ok(entries)
            }) {
                Ok(entries) => ToolResult::Ok {
                    result: json!(entries),
                },
                Err(msg) => ToolResult::Error { message: msg },
            }
        }
        ToolCall::ReadFile { path } => {
            match resolve_workspace_path(&path).and_then(|p| {
                fs::read_to_string(&p)
                    .map_err(|e| format!("Failed to read {}: {e}", p.display()))
            }) {
                Ok(content) => ToolResult::Ok {
                    result: json!({ "content": content }),
                },
                Err(msg) => ToolResult::Error { message: msg },
            }
        }
        ToolCall::WriteFile { path, content } => {
            println!("[DEBUG] path = {}, content = {}", path, content);
            match resolve_workspace_path(&path).and_then(|p| {
                if let Some(parent) = p.parent() {
                    fs::create_dir_all(parent)
                        .map_err(|e| format!("Failed to create dirs {}: {e}", parent.display()))?;
                }
                fs::write(&p, content)
                    .map_err(|e| format!("Failed to write {}: {e}", p.display()))
            }) {
                Ok(()) => ToolResult::Ok {
                    result: json!({ "written": true }),
                },
                Err(msg) => ToolResult::Error { message: msg },
            }
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // You can change this to whatever task you want the agent to do.
    let initial_task = "\
create a text file in the workspace with the contents 'hello world'";

    println!("[Agent] Workspace root: {WORKSPACE_ROOT}");
    println!("[Agent] Initial task: {initial_task}");

    let mut agent = Agent::new(initial_task);
    agent.run().await?;
    
    Ok(())
}

/// Extract the JSON part of a reply that may be wrapped in ```json ... ``` fences.
fn extract_json_from_markdown(reply: &str) -> String {
    let trimmed = reply.trim();

    // Case 1: starts with ```json
    if trimmed.starts_with("```json") {
        // Remove leading ```json
        let mut inner = &trimmed["```json".len()..];

        // Strip the first newline if present
        if inner.starts_with('\n') || inner.starts_with('\r') {
            inner = &inner[1..];
        }

        // Trim trailing backticks and whitespace (``` at the end)
        let inner = inner.trim();
        let inner = inner
            .trim_end_matches('`')  // remove trailing ``` if present
            .trim();

        return inner.to_string();
    }

    // Case 2: generic ``` ... ``` without explicitly saying json
    if trimmed.starts_with("```") {
        let mut inner = &trimmed["```".len()..];

        // Strip optional language token until first newline
        if let Some(idx) = inner.find('\n') {
            inner = &inner[idx..];
        }

        if inner.starts_with('\n') || inner.starts_with('\r') {
            inner = &inner[1..];
        }

        let inner = inner.trim();
        let inner = inner
            .trim_end_matches('`')
            .trim();

        return inner.to_string();
    }

    // Otherwise, assume the whole thing is JSON
    trimmed.to_string()
}

