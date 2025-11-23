# sb0

**Turn your Claude agent into a production-ready streaming API in 5 minutes.**

`sb0` is an open-source CLI tool that lets you build Python Claude Agent SDK agents in standard, ready-to-deploy containers.

## Setup


### 1. Install the CLI
```bash
curl -fsSL https://raw.githubusercontent.com/terminal-use/sb0-cli/main/install.sh | bash
```

This will download the latest binary for your platform and install it to `~/.local/bin`.

### 2. Verify Installation

```bash
sb0 --help
```

### 3. Create your first agent!

Go to [sb0 docs](https://docs.sb0.dev/) to create your first agent!


## Troubleshooting

### "command not found: sb0"

Eensure `~/.local/bin` is in your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.) to make it permanent.