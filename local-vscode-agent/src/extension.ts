import * as vscode from 'vscode';
import * as path from 'path';

type ChatRole = 'system' | 'user' | 'assistant' | 'tool';

type ChatMessage = {
  role: ChatRole;
  content: string;
};

type ToolCall = {
  name: string;
  arguments: Record<string, unknown>;
};

type AgentConfig = {
  baseUrl: string;
  apiKey: string;
  model: string;
  maxToolRounds: number;
};

type ToolResult = {
  ok: boolean;
  content: string;
};

const OUTPUT = vscode.window.createOutputChannel('Local Qwen Agent');

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.commands.registerCommand('localQwenAgent.openPanel', () => {
      LocalAgentPanel.createOrShow(context.extensionUri);
    })
  );
}

export function deactivate(): void {
  OUTPUT.dispose();
}

class LocalAgentPanel {
  private static currentPanel: LocalAgentPanel | undefined;
  private readonly panel: vscode.WebviewPanel;
  private readonly disposables: vscode.Disposable[] = [];
  private readonly history: ChatMessage[] = [];

  static createOrShow(extensionUri: vscode.Uri): void {
    if (LocalAgentPanel.currentPanel) {
      LocalAgentPanel.currentPanel.panel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      'localQwenAgent',
      'Local Qwen Agent',
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [extensionUri],
      }
    );

    LocalAgentPanel.currentPanel = new LocalAgentPanel(panel);
  }

  private constructor(panel: vscode.WebviewPanel) {
    this.panel = panel;
    this.panel.webview.html = this.html();

    this.panel.onDidDispose(() => this.dispose(), null, this.disposables);
    this.panel.webview.onDidReceiveMessage(
      async (message: { type: string; text?: string }) => {
        if (message.type === 'send' && typeof message.text === 'string') {
          await this.handleUserMessage(message.text);
        }
        if (message.type === 'reset') {
          this.history.length = 0;
          await this.post('reset', 'Conversation reset.');
        }
      },
      null,
      this.disposables
    );
  }

  private dispose(): void {
    LocalAgentPanel.currentPanel = undefined;
    while (this.disposables.length) {
      const disposable = this.disposables.pop();
      disposable?.dispose();
    }
  }

  private config(): AgentConfig {
    const cfg = vscode.workspace.getConfiguration('localQwenAgent');
    return {
      baseUrl: String(cfg.get('baseUrl') ?? 'http://10.0.0.154:4000').replace(/\/$/, ''),
      apiKey: String(cfg.get('apiKey') ?? 'local-dev-key'),
      model: String(cfg.get('model') ?? 'qwen-coder-ablit'),
      maxToolRounds: Number(cfg.get('maxToolRounds') ?? 8),
    };
  }

  private async handleUserMessage(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) return;

    this.history.push({ role: 'user', content: trimmed });
    await this.post('user', trimmed);
    await this.post('status', 'Thinking...');

    try {
      const final = await this.runAgentLoop();
      await this.post('assistant', final || '(No response)');
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      OUTPUT.appendLine(message);
      await this.post('error', message);
    } finally {
      await this.post('status', 'Ready.');
    }
  }

  private async runAgentLoop(): Promise<string> {
    const cfg = this.config();
    const messages: ChatMessage[] = [
      { role: 'system', content: systemPrompt() },
      ...this.history.slice(-20),
    ];

    let lastAssistant = '';

    for (let round = 0; round < cfg.maxToolRounds; round += 1) {
      const assistant = await callOpenAICompatible(cfg, messages);
      lastAssistant = assistant;
      const calls = parseToolCalls(assistant);

      if (calls.length === 0) {
        this.history.push({ role: 'assistant', content: assistant });
        return assistant;
      }

      messages.push({ role: 'assistant', content: assistant });
      await this.post('toolPlan', `Detected ${calls.length} tool call(s).`);

      for (const call of calls) {
        await this.post('toolCall', JSON.stringify(call, null, 2));
        const result = await runTool(call);
        const toolText = `[tool:${call.name}] ${result.ok ? 'OK' : 'FAIL'}\n${result.content}`;
        messages.push({ role: 'tool', content: toolText });
        await this.post(result.ok ? 'toolResult' : 'error', toolText);
      }

      messages.push({
        role: 'user',
        content:
          'Continue. Use the tool observations above. If the task is complete, answer normally without another JSON tool call.',
      });
    }

    this.history.push({ role: 'assistant', content: lastAssistant });
    return `${lastAssistant}\n\n[Stopped after max tool rounds.]`;
  }

  private async post(type: string, text: string): Promise<void> {
    await this.panel.webview.postMessage({ type, text });
  }

  private html(): string {
    const nonce = String(Date.now());
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Local Qwen Agent</title>
<style>
  body { font-family: var(--vscode-font-family); margin: 0; color: var(--vscode-foreground); background: var(--vscode-editor-background); }
  header { padding: 10px 12px; border-bottom: 1px solid var(--vscode-panel-border); font-weight: 700; }
  #log { padding: 12px; overflow-y: auto; height: calc(100vh - 150px); box-sizing: border-box; }
  .msg { white-space: pre-wrap; border: 1px solid var(--vscode-panel-border); border-radius: 8px; padding: 10px; margin: 8px 0; }
  .user { background: var(--vscode-input-background); }
  .assistant { background: var(--vscode-editor-inactiveSelectionBackground); }
  .toolCall, .toolResult, .toolPlan { font-family: var(--vscode-editor-font-family); font-size: 12px; }
  .toolCall { border-color: var(--vscode-notificationsWarningIcon-foreground); }
  .toolResult { border-color: var(--vscode-notificationsInfoIcon-foreground); }
  .error { border-color: var(--vscode-notificationsErrorIcon-foreground); color: var(--vscode-errorForeground); }
  footer { display: flex; gap: 8px; padding: 10px; border-top: 1px solid var(--vscode-panel-border); }
  textarea { flex: 1; min-height: 62px; resize: vertical; color: var(--vscode-input-foreground); background: var(--vscode-input-background); border: 1px solid var(--vscode-input-border); padding: 8px; }
  button { color: var(--vscode-button-foreground); background: var(--vscode-button-background); border: none; padding: 8px 12px; cursor: pointer; }
  button.secondary { background: var(--vscode-button-secondaryBackground); color: var(--vscode-button-secondaryForeground); }
  #status { padding: 4px 12px; font-size: 12px; opacity: 0.8; }
</style>
</head>
<body>
<header>Local Qwen Agent — LiteLLM/Ollama workspace tools</header>
<div id="status">Ready.</div>
<div id="log"></div>
<footer>
  <textarea id="input" placeholder="Ask for code review, file edits, repo summary, tests... Use Shift+Enter for newline."></textarea>
  <button id="send">Send</button>
  <button id="reset" class="secondary">Reset</button>
</footer>
<script nonce="${nonce}">
  const vscode = acquireVsCodeApi();
  const log = document.getElementById('log');
  const status = document.getElementById('status');
  const input = document.getElementById('input');
  function add(type, text) {
    if (type === 'status') { status.textContent = text; return; }
    if (type === 'reset') { log.innerHTML = ''; }
    const el = document.createElement('div');
    el.className = 'msg ' + type;
    el.textContent = text;
    log.appendChild(el);
    log.scrollTop = log.scrollHeight;
  }
  window.addEventListener('message', event => add(event.data.type, event.data.text));
  document.getElementById('send').addEventListener('click', () => {
    vscode.postMessage({ type: 'send', text: input.value });
    input.value = '';
  });
  document.getElementById('reset').addEventListener('click', () => vscode.postMessage({ type: 'reset' }));
  input.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      vscode.postMessage({ type: 'send', text: input.value });
      input.value = '';
    }
  });
</script>
</body>
</html>`;
  }
}

function systemPrompt(): string {
  return `You are Local Qwen Agent inside VS Code. You can use workspace tools by emitting strict JSON only when a tool is needed.

Supported tool calls:
{"name":"list_files","arguments":{"pattern":"**/*","max_results":200}}
{"name":"read_file","arguments":{"path":"relative/path.ts","max_bytes":12000}}
{"name":"write_file","arguments":{"path":"relative/path.ts","content":"full file content"}}
{"name":"replace_in_file","arguments":{"path":"relative/path.ts","search":"exact text","replace":"new text"}}
{"name":"search_text","arguments":{"query":"text or regex","files_to_include":"**/*.{ts,js,json,md}"}}
{"name":"run_command","arguments":{"command":"npm test","cwd":"."}}

Rules:
- Emit one JSON object per tool call. No markdown fences around tool JSON.
- Use tools for repository inspection instead of pretending.
- Keep paths relative to the workspace root.
- Never access files outside the workspace.
- For write_file, provide the complete intended file content.
- For run_command, use safe project commands only. No sudo, rm -rf, curl | sh, credential dumping, or destructive system operations.
- Once done, answer normally in prose.`;
}

async function callOpenAICompatible(cfg: AgentConfig, messages: ChatMessage[]): Promise<string> {
  const url = `${cfg.baseUrl}/v1/chat/completions`;
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${cfg.apiKey}`,
    },
    body: JSON.stringify({
      model: cfg.model,
      messages,
      temperature: 0.15,
      stream: false,
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`LiteLLM request failed ${response.status}: ${body}`);
  }

  const json = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  return json.choices?.[0]?.message?.content ?? '';
}

function parseToolCalls(text: string): ToolCall[] {
  const calls: ToolCall[] = [];
  const candidates = extractJsonObjects(text);

  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate) as unknown;
      if (isToolCall(parsed)) calls.push(parsed);
    } catch {
      // Ignore non-JSON fragments.
    }
  }

  return calls;
}

function extractJsonObjects(text: string): string[] {
  const result: string[] = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escape = false;

  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (char === '\\') {
      escape = true;
      continue;
    }
    if (char === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (char === '{') {
      if (depth === 0) start = i;
      depth += 1;
    }
    if (char === '}') {
      depth -= 1;
      if (depth === 0 && start >= 0) {
        result.push(text.slice(start, i + 1));
        start = -1;
      }
    }
  }

  return result;
}

function isToolCall(value: unknown): value is ToolCall {
  if (!value || typeof value !== 'object') return false;
  const candidate = value as { name?: unknown; arguments?: unknown };
  return typeof candidate.name === 'string' && !!candidate.arguments && typeof candidate.arguments === 'object';
}

async function runTool(call: ToolCall): Promise<ToolResult> {
  switch (call.name) {
    case 'list_files': return listFiles(call.arguments);
    case 'read_file': return readFileTool(call.arguments);
    case 'write_file': return writeFileTool(call.arguments);
    case 'replace_in_file': return replaceInFileTool(call.arguments);
    case 'search_text': return searchTextTool(call.arguments);
    case 'run_command': return runCommandTool(call.arguments);
    default: return { ok: false, content: `Unknown tool: ${call.name}` };
  }
}

function workspaceRoot(): vscode.Uri {
  const folder = vscode.workspace.workspaceFolders?.[0];
  if (!folder) throw new Error('No workspace folder is open.');
  return folder.uri;
}

function safeWorkspaceUri(relativePath: unknown): vscode.Uri {
  if (typeof relativePath !== 'string' || !relativePath.trim()) throw new Error('Missing path.');
  if (path.isAbsolute(relativePath)) throw new Error('Absolute paths are not allowed.');
  const root = workspaceRoot();
  const normalized = path.posix.normalize(relativePath.replace(/\\/g, '/'));
  if (normalized.startsWith('..')) throw new Error('Path escapes workspace.');
  return vscode.Uri.joinPath(root, ...normalized.split('/').filter(Boolean));
}

async function listFiles(args: Record<string, unknown>): Promise<ToolResult> {
  const pattern = typeof args.pattern === 'string' ? args.pattern : '**/*';
  const maxResults = typeof args.max_results === 'number' ? args.max_results : 200;
  const files = await vscode.workspace.findFiles(pattern, '**/{node_modules,.git,out,dist,build}/**', maxResults);
  const root = workspaceRoot();
  const lines = files.map(file => path.posix.relative(root.path, file.path)).sort();
  return { ok: true, content: lines.join('\n') || '(no files)' };
}

async function readFileTool(args: Record<string, unknown>): Promise<ToolResult> {
  const uri = safeWorkspaceUri(args.path);
  const maxBytes = typeof args.max_bytes === 'number' ? args.max_bytes : 12000;
  const bytes = await vscode.workspace.fs.readFile(uri);
  const sliced = bytes.slice(0, Math.max(0, maxBytes));
  const text = Buffer.from(sliced).toString('utf8');
  const suffix = bytes.length > sliced.length ? `\n\n[truncated ${bytes.length - sliced.length} bytes]` : '';
  return { ok: true, content: text + suffix };
}

async function writeFileTool(args: Record<string, unknown>): Promise<ToolResult> {
  const uri = safeWorkspaceUri(args.path);
  const content = typeof args.content === 'string' ? args.content : undefined;
  if (content === undefined) throw new Error('Missing content.');
  await vscode.workspace.fs.createDirectory(vscode.Uri.joinPath(uri, '..'));
  await vscode.workspace.fs.writeFile(uri, Buffer.from(content, 'utf8'));
  return { ok: true, content: `Wrote ${args.path}` };
}

async function replaceInFileTool(args: Record<string, unknown>): Promise<ToolResult> {
  const uri = safeWorkspaceUri(args.path);
  const search = typeof args.search === 'string' ? args.search : undefined;
  const replace = typeof args.replace === 'string' ? args.replace : undefined;
  if (search === undefined || replace === undefined) throw new Error('Missing search/replace.');
  const current = Buffer.from(await vscode.workspace.fs.readFile(uri)).toString('utf8');
  if (!current.includes(search)) return { ok: false, content: `Search text not found in ${args.path}` };
  const next = current.replace(search, replace);
  await vscode.workspace.fs.writeFile(uri, Buffer.from(next, 'utf8'));
  return { ok: true, content: `Updated ${args.path}` };
}

async function searchTextTool(args: Record<string, unknown>): Promise<ToolResult> {
  const query = typeof args.query === 'string' ? args.query : undefined;
  const include = typeof args.files_to_include === 'string' ? args.files_to_include : '**/*';
  if (!query) throw new Error('Missing query.');
  const files = await vscode.workspace.findFiles(include, '**/{node_modules,.git,out,dist,build}/**', 500);
  const root = workspaceRoot();
  const regex = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');
  const matches: string[] = [];
  for (const file of files) {
    const text = Buffer.from(await vscode.workspace.fs.readFile(file)).toString('utf8');
    const lines = text.split(/\r?\n/);
    lines.forEach((line, index) => {
      if (regex.test(line)) matches.push(`${path.posix.relative(root.path, file.path)}:${index + 1}: ${line.trim()}`);
    });
    if (matches.length >= 100) break;
  }
  return { ok: true, content: matches.join('\n') || '(no matches)' };
}

async function runCommandTool(args: Record<string, unknown>): Promise<ToolResult> {
  const command = typeof args.command === 'string' ? args.command.trim() : '';
  const cwd = typeof args.cwd === 'string' ? args.cwd : '.';
  if (!command) throw new Error('Missing command.');
  if (/\b(sudo|rm\s+-rf|curl\b.*\|\s*sh|wget\b.*\|\s*sh|dd\b|mkfs\b)\b/.test(command)) {
    return { ok: false, content: `Blocked unsafe command: ${command}` };
  }

  const approved = await vscode.window.showWarningMessage(
    `Run workspace command?\n${command}`,
    { modal: true },
    'Run'
  );
  if (approved !== 'Run') return { ok: false, content: 'Command declined by user.' };

  const terminal = vscode.window.createTerminal({ name: 'Local Qwen Agent', cwd: safeWorkspaceUri(cwd) });
  terminal.show(true);
  terminal.sendText(command, true);
  return { ok: true, content: `Started terminal command: ${command}` };
}
