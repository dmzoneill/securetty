# Daemon Mode

The securetty daemon is a host-side background process that polls the dispatcher for pending jobs and executes them automatically using the securetty CLI. It provides always-on agent execution without requiring manual intervention.

## How It Works

The daemon runs on the host (not inside a container) and operates in a continuous loop:

1. Polls the dispatcher API (`/jobs?status=pending`) every 10 seconds
2. Claims available pending jobs up to the configured concurrency limit
3. Launches each job as a sandboxed securetty agent session via the CLI
4. Tracks active sessions and picks up new work as slots become available
5. Logs all activity to `~/.securetty/daemon.log`

Each job executes inside the normal securetty container sandbox with full credential isolation, egress filtering, and security controls.

## Start / Stop / Status

```bash
# Start daemon in background
securetty daemon start

# Start in foreground (for systemd or debugging)
securetty daemon start --foreground

# Check daemon status and recent activity
securetty daemon status

# Stop daemon gracefully (sends SIGTERM, waits for active jobs)
securetty daemon stop
```

The daemon writes its PID to `~/.securetty/daemon.pid` and logs to `~/.securetty/daemon.log`.

## Bot Account Configuration

For autonomous commits, the daemon can use a separate git identity so that machine-generated commits are distinguishable from human ones. Create `~/.securetty/bot.yaml`:

```yaml
git:
  user.name: securetty-bot
  user.email: securetty-bot@example.com
```

When this file exists, the daemon passes the bot identity to agent sessions via environment variables. This identity is used for any git commits made during autonomous job execution, keeping the audit trail clear.

## Integration with Dispatcher

The daemon is a consumer of the dispatcher job queue. Jobs enter the queue through:

- **CLI dispatch:** `securetty dispatch "fix the lint errors in src/app.py"`
- **GitHub webhooks:** POST to `/webhook/github` (push, PR, issue events)
- **GitLab webhooks:** POST to `/webhook/gitlab` (merge request, pipeline events)
- **Jira webhooks:** POST to `/webhook/jira` (issue transitions)
- **Polling triggers:** `securetty watch myorg/myrepo --source github --event push`

The dispatcher routes work items through `workflows.toon` skill matching and queues them. The daemon picks up pending jobs and executes them. The dispatcher's internal scheduler handles jobs when the daemon is not running.

### Typical flow

```
webhook/trigger --> dispatcher (queues job) --> daemon (polls, executes)
                                                  |
                                                  v
                                            securetty run <agent>
                                            (sandboxed container)
```

## Resource Limits and Monitoring

### Concurrency

The daemon enforces a maximum number of concurrent agent sessions (default: 3). Configure via environment variable:

```bash
export SECURETTY_DAEMON_MAX_SESSIONS=5
```

Each session runs as a separate securetty container with its own resource limits (PID cap, tmpfs size, read-only rootfs) as defined by the securetty CLI.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECURETTY_DAEMON_POLL` | `10` | Poll interval in seconds |
| `SECURETTY_DAEMON_MAX_SESSIONS` | `3` | Max concurrent agent sessions |
| `SECURETTY_DISPATCHER_URL` | `https://securetty-dispatcher:8900` | Dispatcher API endpoint |

### Monitoring

Check daemon health:

```bash
# Process status and recent activity
securetty daemon status

# Tail the daemon log
tail -f ~/.securetty/daemon.log

# Check dispatcher queue depth
securetty jobs pending

# Container resource usage for active sessions
securetty top
```

Session outcomes are logged to `~/.securetty/outcomes/YYYY-MM-DD.jsonl` by the standard securetty session logger. Cost data goes to `~/.securetty/cost/YYYY-MM-DD.jsonl`.

### Graceful shutdown

On SIGTERM (or `securetty daemon stop`), the daemon:

1. Stops polling for new jobs
2. Sends SIGTERM to all active agent sessions
3. Waits up to 10 seconds for sessions to exit
4. Force-kills any remaining processes
5. Removes the PID file and exits

## Systemd User Service

For automatic startup, install the provided systemd user unit:

```bash
mkdir -p ~/.config/systemd/user
cp roles/containers/files/securetty-daemon.service ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable securetty-daemon
systemctl --user start securetty-daemon
```

Check service status:

```bash
systemctl --user status securetty-daemon
journalctl --user -u securetty-daemon -f
```

Override defaults via a drop-in:

```bash
systemctl --user edit securetty-daemon
```

```ini
[Service]
Environment=SECURETTY_DAEMON_MAX_SESSIONS=5
Environment=SECURETTY_DAEMON_POLL=30
```

The unit is configured with `Restart=on-failure` and `RestartSec=30` so systemd will restart the daemon if it crashes.
