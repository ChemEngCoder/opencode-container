# OpenCode Docker

Run the [OpenCode](https://opencode.ai) CLI inside a locked-down Docker container: read-only root filesystem, all Linux capabilities dropped, privilege escalation blocked, and API keys loaded from files instead of the command line. Your current directory is mounted as the only writable workspace.

Two ways to run it:

- **`bin/opencode-docker`** (recommended) — persists everything to `~/.opencode-docker/` and works from any directory.
- **`make run`** (development of this repo) — uses local `./homebase`, `./workspace`, and `./secrets`.

<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="OpenCode Docker hero: the real docker run flags the wrapper applies — read-only filesystem, all capabilities dropped, no-new-privileges, 4 GB memory and 4 CPU limits, secrets mounted read-only, current directory as the only writable workspace">
</p>

## Getting Started

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) installed on your machine.
- Make
- `curl` and `jq` (required for `make build-latest`)

### Quick Start

```bash
# Build the image
make build

# Add a provider API key (one-time)
mkdir -p ~/.opencode-docker/secrets
chmod 700 ~/.opencode-docker/secrets
echo "your-api-key" > ~/.opencode-docker/secrets/anthropic_api_key
chmod 600 ~/.opencode-docker/secrets/*

# Run with the wrapper script (recommended)
bin/opencode-docker
```

The OpenCode TUI starts inside the container. Your current directory is mounted at `/workspace`; sessions, cache, and settings persist in `~/.opencode-docker/`. See [Secrets Management](#secrets-management) for other providers.

### Using the Wrapper Script

The `bin/opencode-docker` script is the recommended way to run OpenCode Docker. It:

- Persists all data to `~/.opencode-docker/` (sessions, cache, settings)
- Reads secrets from `~/.opencode-docker/secrets/`
- Uses the current directory as the workspace
- Works from any directory once added to your PATH

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-w`, `--websearch` | off | Enable Exa web search |
| `-e`, `--experimental` | off | Enable experimental features and models |
| `-u`, `--update-config` | off | Overwrite `~/.opencode-docker/config/` with the repo's `config/` |
| `--memory` | `4g` | Container memory limit |
| `--cpus` | `4` | Container CPU count |

Everything else is passed through to the OpenCode CLI — including short flags like `-m`/`--model`, `-c`/`--continue`, and `-s`/`--session`, as well as subcommands. Run `opencode-docker --help` to see them all.

#### Adding to PATH

Adjust the path below to where you cloned this repository.

**Bash** — add to `~/.bashrc`, then run `source ~/.bashrc`:

```bash
export PATH="$HOME/git/opencode-docker/bin:$PATH"
```

**Fish**:

```fish
fish_add_path $HOME/git/opencode-docker/bin
```

#### Usage

Once added to your PATH, you can run from any directory:

```bash
# Run in the current directory
opencode-docker

# Continue a session (passed through to OpenCode)
opencode-docker -s ses_2d068fdfaffefxNTts5doK0upT

# Pass subcommands through (cwd is the mounted workspace)
opencode-docker -e -w auth logout
opencode-docker run "fix the login bug"

# Override the workspace directory
OPENCODE_WORKSPACE=/path/to/project opencode-docker

# Raise resource limits for a heavy session
opencode-docker --memory 8g --cpus 8
```

## Security Features

The container applies several independent layers of restriction:

- **Distroless runtime:** the final image has no shell and no package manager
- **Read-only root filesystem:** only `/tmp` (tmpfs) and mounted volumes are writable
- **Dropped capabilities:** `--cap-drop=ALL` removes all Linux capabilities (principle of least privilege)
- **No privilege escalation:** `--security-opt=no-new-privileges` blocks setuid/setgid exploits
- **Non-root user:** runs as UID 1000 (configurable at build time)
- **Resource limits:** the wrapper defaults to 4 GB memory / 4 CPUs (override with `-m`/`-c`); `make run` uses 2 GB / 2 CPUs
- **File-based secrets:** keys mounted read-only at `/run/secrets` — never baked into the image or passed on the Docker command line

## Secrets Management

API keys live as plain files on the host and are loaded at container start — they are never baked into the image or passed on the Docker command line.

### How It Works

1. Set up one file per key as shown in [Quick Start](#quick-start) (`~/.opencode-docker/secrets/`, directory `700`, files `600`).
2. The runtime bootstrap (`bootstrap.py`) reads every file in `/run/secrets` and exports it as an environment variable:
   - Filenames are uppercased; dashes and dots become underscores
   - Example: `anthropic_api_key` becomes `ANTHROPIC_API_KEY`
3. Any filename works — the table below lists the providers OpenCode commonly uses.

### Commonly Used Secrets

| Filename | Environment Variable | Provider |
|----------|---------------------|----------|
| `anthropic_api_key` | `ANTHROPIC_API_KEY` | Anthropic |
| `openai_api_key` | `OPENAI_API_KEY` | OpenAI |
| `context7_api_key` | `CONTEXT7_API_KEY` | Context7 MCP |
| `google_application_credentials` | `GOOGLE_APPLICATION_CREDENTIALS` | Vertex AI |
| `aws_access_key_id` | `AWS_ACCESS_KEY_ID` | AWS Bedrock |
| `aws_secret_access_key` | `AWS_SECRET_ACCESS_KEY` | AWS Bedrock |

**Note:** the wrapper script converts these files into a temporary `--env-file` for `docker run`, so inside the container the keys appear as environment variables. The file-based layout keeps them out of image layers, the Docker command line, and shell history.

## Data Persistence & Configuration

When using the wrapper script (`bin/opencode-docker`):

| Data | Location | Description |
|------|----------|-------------|
| **Home Directory** | `~/.opencode-docker/` | OpenCode cache, plugins, settings, sessions |
| **Secrets** | `~/.opencode-docker/secrets/` | API keys and credentials |
| **Config** | `./config/` (this repo) | OpenCode configuration, MCP servers, custom skills |
| **Workspace** | Current directory | Your project files |

When using `make run` (development only):

| Data | Location | Description |
|------|----------|-------------|
| **Home Directory** | `./homebase/` | Local persistent home |
| **Secrets** | `./secrets/` | Local secrets |
| **Config** | `./config/` | OpenCode config |
| **Workspace** | `./workspace/` | Local workspace |

## Advanced Usage

### Development Commands

```bash
make build                      # Build with auto-detected UID/GID
make build VERSION=1.18.11      # Build a specific OpenCode version
make build-latest               # Build the latest OpenCode release
make tag-latest VERSION=1.18.11 # Tag a built version as latest
make run                        # Dev run (uses ./homebase, ./workspace, ./secrets)
make shell                      # Debug shell (builder-tools stage with bash)
make clean                      # Remove image
```

The version examples above match `ARG OPENCODE_VERSION` in the Dockerfile; check there for the current default.

### Manual Docker Run

For advanced users who need custom container configuration. These flags mirror `make run` (2 GB / 2 CPUs); the wrapper script is the maintained reference and defaults to 4 GB / 4 CPUs. Adjust the config mount to your clone path.

```bash
docker run --rm -it \
  --workdir /workspace \
  --read-only \
  --tmpfs /tmp:exec,size=512m \
  --cap-drop ALL \
  --security-opt=no-new-privileges \
  --memory=2g \
  --cpus=2 \
  -v ~/.opencode-docker:/app:rw \
  -v /path/to/opencode-docker/config:/app/.config/opencode:rw \
  -v $(pwd):/workspace:rw \
  -v ~/.opencode-docker/secrets:/run/secrets:ro \
  opencode-docker
```

### Building Manually

```bash
# Default UID/GID (1000)
docker build -t opencode-docker .

# With your UID/GID (recommended)
docker build --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) -t opencode-docker .

# With version tag
docker build --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) -t opencode-docker:1.18.11 .
```

### Runtime Details

The image uses a multi-stage build with a distroless runtime:

- **Base:** `gcr.io/distroless/base-debian13` (no shell, no package manager)
- **Node.js:** Node 24 from NodeSource, runtime dependencies extracted via `collect-runtime-deps.sh`
- **Python:** Python 3 with venv support from Debian 13
- **OpenCode:** installed via the official, checksum-verified installer in the build stage
- **Bootstrap:** `bootstrap.py` loads secrets from `/run/secrets`, starts Xvfb, then execs OpenCode

## Star History

<a href="https://www.star-history.com/?repos=pkhamre%2Fopencode-docker&type=timeline&logscale=&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=pkhamre/opencode-docker&type=timeline&theme=dark&logscale&legend=bottom-right&sealed_token=G0ZZ49vg7A5UHyiEXWfNNUyHLEJ-o9l5Z23UJ_fRokVF3970EV9C2Qy1Sh8K0_-PbMrFMmDdsjhltJZzZlAu_mxFViWtIAWbZ4DnEBmzlOJi_sGHsD5K7gPyJ3XKbB1OcmJGtHBFCS6oBq4_cxUrlpMgaf6J6nxdfNPGz4CyuWUAKGQ6jFqYUGGiONHY" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=pkhamre/opencode-docker&type=timeline&logscale&legend=bottom-right&sealed_token=G0ZZ49vg7A5UHyiEXWfNNUyHLEJ-o9l5Z23UJ_fRokVF3970EV9C2Qy1Sh8K0_-PbMrFMmDdsjhltJZzZlAu_mxFViWtIAWbZ4DnEBmzlOJi_sGHsD5K7gPyJ3XKbB1OcmJGtHBFCS6oBq4_cxUrlpMgaf6J6nxdfNPGz4CyuWUAKGQ6jFqYUGGiONHY" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=pkhamre/opencode-docker&type=timeline&logscale&legend=bottom-right&sealed_token=G0ZZ49vg7A5UHyiEXWfNNUyHLEJ-o9l5Z23UJ_fRokVF3970EV9C2Qy1Sh8K0_-PbMrFMmDdsjhltJZzZlAu_mxFViWtIAWbZ4DnEBmzlOJi_sGHsD5K7gPyJ3XKbB1OcmJGtHBFCS6oBq4_cxUrlpMgaf6J6nxdfNPGz4CyuWUAKGQ6jFqYUGGiONHY" />
 </picture>
</a>
