# pls

AI-powered CLI assistant. Type what you want in natural language, and `pls` figures out the shell commands.

```
$ pls 'stop all processes using port 1380'
```

```
$ pls '1380 포트 서비스를 다 멈춰줘'
```

Both work. `pls` understands any language.

## How it works

1. You describe a task in plain text
2. An LLM interprets it and generates shell commands
3. Commands run in a loop: execute, observe output, decide next step
4. Destructive commands (kill, rm, etc.) require your confirmation

## Install

Requires [Zig 0.15+](https://ziglang.org/download/).

```bash
git clone <repo-url> && cd pls
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/pls`. Add it to your `$PATH`:

```bash
cp zig-out/bin/pls ~/.local/bin/
# or
sudo cp zig-out/bin/pls /usr/local/bin/
```

## Setup

Run the interactive setup wizard:

```
$ pls init

  Welcome to pls! Let's get you set up.

  Select your LLM provider:
    1) Anthropic (Claude)
    2) OpenAI (GPT)
    3) Google Gemini
    4) Ollama (local)

  Choice [1]: _
```

Config is saved to `~/.config/pls/config.toml`.

### Supported providers

| Provider | Auth | Use case |
|----------|------|----------|
| **Anthropic** | API key | Best tool-use, recommended |
| **OpenAI** | API key | GPT-4o, widely available |
| **Gemini** | API key | Google's Gemini models |
| **Ollama** | None (local) | Offline, private, free |

### Environment variables

These override the config file:

```bash
export PLS_PROVIDER=gemini        # anthropic | openai | gemini | ollama
export DO_PROVIDER=gemini         # same as PLS_PROVIDER (legacy alias)
export PLS_CONFIRM=destructive    # all | destructive | none
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GEMINI_API_KEY=AIza...
export OLLAMA_HOST=http://localhost:11434
export OLLAMA_MODEL=llama3.2
```

## Usage

```bash
# Basic usage
pls 'stop all processes using port 1380'
pls 'find all files larger than 1GB in home directory'
pls 'create a git branch called feature/auth'
pls 'compress all jpg files in this folder'
pls 'show disk usage by directory'

# Skip confirmation prompts
pls -y 'kill process on port 3000'

# Dry run (show commands without executing)
pls --dry-run 'clean up docker containers'

# Override provider or model for one invocation
pls --provider openai --model gpt-4o 'explain this error'

# Pipe a task from stdin
echo 'find large files over 1GB' | pls
```

## CLI reference

```
pls <task>                   Run a natural language task
pls init                     Interactive setup wizard
pls config                   Interactive config editor
pls config show              Show active configuration

--confirm <mode>             Confirmation mode: all | destructive | none
--yes, -y                    Shorthand for --confirm=none
--provider <name>            Override LLM provider: anthropic | openai | gemini | ollama
--model <name>               Override model name for this invocation
--max-turns <n>              Maximum agent turns (default: 20)
--dry-run                    Show commands without executing them
--version, -v                Show version
--help, -h                   Show this help

Piping:
  echo 'your task' | pls
```

## Config file

`~/.config/pls/config.toml`:

```toml
provider = "anthropic"

anthropic_api_key = "sk-ant-..."
anthropic_model = "claude-sonnet-4-5-20250514"

openai_api_key = "sk-..."
openai_model = "gpt-4o"

gemini_api_key = "AIza..."
gemini_model = "gemini-2.5-flash"

ollama_host = "http://localhost:11434"
ollama_model = "llama3.1"
```

## Safety

- Destructive commands (`kill`, `rm`, `rmdir`, `dd`, `shutdown`, etc.) trigger a confirmation prompt
- Use `--dry-run` to preview what commands would run
- Use `-y` to skip confirmations (power users only)
- The agent loop is capped at 20 turns to prevent runaway execution

## Architecture

Written in Zig 0.15. Single binary, no runtime dependencies.

```
src/
  main.zig              Entry point, arg parsing, subcommand routing
  agent.zig             Tool-calling loop (LLM -> tool -> observe -> repeat)
  config.zig            Config file parsing (~/.config/pls/config.toml)
  config_editor.zig     Interactive config editor (terminal UI)
  init.zig              Interactive setup wizard
  tty.zig               TTY helpers (readLine, readLineMasked with echo off)
  llm/
    provider.zig        Shared types (Message, Tool, ToolCall, etc.)
    anthropic.zig       Anthropic Claude API
    openai.zig          OpenAI GPT API
    gemini.zig          Google Gemini API
    ollama.zig          Ollama local API (delegates to openai.zig format)
    http_client.zig     HTTP POST helper using std.http.Client
    json_helpers.zig    JSON serialization for API request bodies
  tools/
    shell.zig           Shell command execution via /bin/sh
    confirm.zig         ask() y/N prompt and askUser() numbered options
```

## License

MIT
