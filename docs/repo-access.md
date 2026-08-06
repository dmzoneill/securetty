# Repository Access

How securetty containers access source code repositories.

## Repository Table

| Repository | Hosting | CLI Tool | Auth Token | Auth Mechanism | Network Requirements |
|-----------|---------|----------|------------|---------------|---------------------|
| securetty | GitHub (public) | `gh` | `GITHUB_TOKEN` | PAT via GNU pass (`github.com/profile-readme`) | github.com in egress allowlist |
| Personal projects | GitHub | `gh` | `GITHUB_TOKEN` | Same PAT as above | github.com, githubusercontent.com in egress allowlist |
| automation-analytics-backend | GitLab internal (`gitlab.cee.redhat.com`) | `glab` | `GITLAB_TOKEN` | PAT via GNU pass (`redhat.com/gitlab-notifier`) | VPN required; gitlab.cee.redhat.com in egress allowlist; Red Hat internal CA installed in image |
| Other Red Hat internal repos | GitLab internal | `glab` | `GITLAB_TOKEN` | Same PAT, aliased as `GITLAB_API_TOKEN` | VPN required; redhat.com in egress allowlist |
| Jira issues | Atlassian Cloud | curl / MCP skill | `JIRA_JPAT` | PAT via GNU pass (`redhat.com/jira-ticket-closer`) | atlassian.net, atlassian.com in egress allowlist |
| Slack workspace | Enterprise Slack | curl / MCP skill | `SLACK_XOXC_TOKEN` + `SLACK_D_COOKIE` | Session cookies extracted from Chrome at container start | slack.com, enterprise.slack.com in egress allowlist |
| WordPress (feeditout.com) | Self-hosted | curl / MCP skill | `WORDPRESS_PASSWORD` + `WORDPRESS_APPLICATION` | Application password via GNU pass | feeditout.com in egress allowlist |
| Google Workspace | Google Cloud | Python SDK | Vertex env vars (`ANTHROPIC_VERTEX_PROJECT_ID`, etc.) | gcloud ADC via `~/.config/gcloud/` mount | googleapis.com, google.com in egress allowlist |

## Authentication Flow

1. **At container start**: `generate-env.sh` reads secrets from GNU pass store on host, sources shell profile scripts, and writes `.env` files
2. **Per-service isolation**: OmniRoute gets `.env.omniroute` (provider keys only), CloudCLI gets `.env.cloudcli` (Vertex only), dev container gets the full `.env`
3. **Git operations**: SSH via restricted agent (socket at `/run/ssh-agent.sock`); HTTPS via token in environment (`GITHUB_TOKEN` for gh, `GITLAB_TOKEN` for glab)
4. **VPN-dependent repos**: GitLab internal repos require the host VPN (NetBird/WireGuard) to be connected; aardvark DNS forwards to host resolver which resolves internal domains via VPN; nftables allows VPN CGNAT range (100.64.0.0/10)

## Token Sources

All tokens are stored in GNU pass (GPG-encrypted) and declared in `group_vars/all.yml` under `securetty_pass_keys`. The `generate-env.sh` script resolves them at every container start, so rotating a key in pass takes effect on next container launch without rebuilding.

| Variable | Pass Path | Used By |
|----------|-----------|---------|
| `GITHUB_TOKEN` | `github.com/profile-readme` | gh CLI, GitHub API |
| `GITLAB_TOKEN` | `redhat.com/gitlab-notifier` | glab CLI, GitLab API |
| `JIRA_JPAT` | `redhat.com/jira-ticket-closer` | Jira MCP skill |
| `SLACK_XOXC_TOKEN` | (extracted from Chrome) | Slack MCP skill |
| `SLACK_D_COOKIE` | (extracted from Chrome) | Slack MCP skill |

## SSH Key Access

Git SSH operations use the restricted SSH agent. Only configured keys are loaded (declared in `securetty_ssh_keys` in `all.yml`):

- `dmzoneill-2024` -- primary GitHub/GitLab key
- `id_ecdsa` -- secondary key

The agent socket is mounted read-only at `/run/ssh-agent.sock`. Private key material never enters the container.
