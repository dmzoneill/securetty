# Jira Auto-Triage Agent

The Jira auto-triage agent automatically classifies Jira issues assigned to the operator and routes them for action. It uses Jira labels as a state machine to track processing state, preventing re-processing and giving visibility into what the agent has done.

## How It Works

The system has two components:

1. **Poller** (`securetty-jira-poller.sh`) -- runs in a loop, queries Jira for untriaged issues assigned to the current user, and feeds each one to the triage script.
2. **Triage script** (`securetty-jira-triage.sh`) -- takes a single issue key, reads its details via the Jira REST API, classifies it, and takes the appropriate action.

### Processing flow

```
Jira issue assigned to operator
        |
        v
   poller discovers issue (no agent:* label)
        |
        v
   triage adds agent:triaged label
        |
        v
   classify: needs-info / codeable / skip
        |
        +--> needs-info: post comment, add agent:needs-info
        |
        +--> codeable: add agent:in-progress, dispatch to securetty
        |
        +--> skip: add agent:skipped, log reason
```

## Label-Based State Machine

Labels on the Jira issue track where the issue is in the triage pipeline. The poller only picks up issues that have none of these labels, so each issue is processed exactly once.

```
                    +------------------+
                    |   (no agent:*    |
                    |    label)        |
                    +--------+---------+
                             |
                        poller picks up
                             |
                             v
                    +------------------+
                    |  agent:triaged   |
                    +--------+---------+
                             |
                       classification
                      /      |       \
                     v       v        v
         +-----------+ +----------+ +-----------+
         | agent:    | | agent:   | | agent:    |
         | needs-info| |in-progress| | skipped  |
         +-----------+ +-----+----+ +-----------+
                             |
                        agent works
                             |
                             v
                    +------------------+
                    |  agent:completed |
                    +------------------+
```

Labels used:

| Label | Meaning |
|-------|---------|
| `agent:triaged` | Issue has been seen and classified by the triage agent |
| `agent:needs-info` | Clarification requested; a Jira comment was posted asking specific questions |
| `agent:in-progress` | Dispatched for implementation via the securetty dispatcher |
| `agent:completed` | Work finished successfully |
| `agent:skipped` | Not actionable -- Epic, already Done, has subtasks, or non-technical |
| `agent:blocked` | Blocked on an external dependency (set manually) |

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECURETTY_JIRA_URL` | *(required)* | Jira base URL (e.g., `https://issues.redhat.com`) |
| `SECURETTY_JIRA_USER` | *(optional)* | Jira username for basic auth |
| `JIRA_API_TOKEN` | *(optional)* | Jira API token; falls back to creds proxy at `localhost:9401` |
| `SECURETTY_JIRA_POLL_INTERVAL` | `300` | Seconds between poll cycles |
| `SECURETTY_JIRA_PROJECTS` | `AAP` | Comma-separated Jira project keys to monitor |
| `SECURETTY_DISPATCHER_URL` | *(from daemon)* | Dispatcher endpoint for codeable issue dispatch |

### Jira authentication

The triage agent authenticates to Jira in this priority order:

1. Basic auth: `SECURETTY_JIRA_USER` + `JIRA_API_TOKEN` (username:token)
2. Bearer token: `JIRA_API_TOKEN` alone (OAuth/PAT)
3. Creds proxy: fetches token from `http://localhost:9401/creds/jira_api_token`

The creds proxy approach keeps tokens out of the process environment and is the recommended setup for production.

## Starting the Poller

```bash
# Start in background
securetty jira-triage start

# Start in foreground (for systemd or debugging)
securetty jira-triage start --foreground

# Check status
securetty jira-triage status

# Stop
securetty jira-triage stop
```

Or run the script directly:

```bash
./roles/containers/files/securetty-jira-poller.sh start
./roles/containers/files/securetty-jira-poller.sh status
./roles/containers/files/securetty-jira-poller.sh stop
```

The poller writes its PID to `~/.securetty/jira-poller.pid` and logs to `~/.securetty/jira-triage.log`.

### Multiple projects

Monitor several Jira projects:

```bash
export SECURETTY_JIRA_PROJECTS="AAP,AAH,AAP-GATEWAY"
securetty jira-triage start
```

### Faster polling

For development or high-volume queues:

```bash
export SECURETTY_JIRA_POLL_INTERVAL=60
securetty jira-triage start
```

## How Labels Prevent Re-Processing

The poller's JQL query explicitly excludes issues that carry any `agent:*` label:

```
project IN (AAP) AND assignee = currentUser()
  AND labels NOT IN (agent:triaged, agent:in-progress, agent:completed,
                     agent:skipped, agent:blocked, agent:needs-info)
  AND status NOT IN (Done, Closed, Resolved)
  ORDER BY priority DESC, updated DESC
```

Additionally, the triage script checks for existing `agent:*` labels before processing and exits early if any are found. This double-guard means an issue is never processed twice, even if the poller and triage script overlap.

## Manually Resetting an Issue

To re-triage an issue, remove all `agent:*` labels from it in Jira. The next poll cycle will pick it up again.

Via Jira REST API:

```bash
curl -u "$SECURETTY_JIRA_USER:$JIRA_API_TOKEN" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"update":{"labels":[
    {"remove":"agent:triaged"},
    {"remove":"agent:needs-info"},
    {"remove":"agent:in-progress"},
    {"remove":"agent:completed"},
    {"remove":"agent:skipped"},
    {"remove":"agent:blocked"}
  ]}}' \
  "$SECURETTY_JIRA_URL/rest/api/2/issue/AAP-12345"
```

Or simply remove the labels through the Jira UI.

## Classification Details

### needs-info

The issue is missing information needed to act on it. The triage agent posts a Jira comment with specific clarifying questions and adds the `agent:needs-info` label. Triggers:

- Description shorter than 50 characters
- Bug reports without reproduction steps (looks for "steps to reproduce", numbered lists, etc.)
- Stories without acceptance criteria (looks for "acceptance criteria", "definition of done", etc.)

Once the reporter updates the issue, they (or the operator) should remove the `agent:needs-info` label to re-trigger triage.

### codeable

The issue has clear, actionable requirements. The triage agent:

1. Adds `agent:in-progress` label
2. Dispatches the issue to the securetty dispatcher (via CLI or REST API) for implementation

The dispatcher routes the work through the configured workflow (skill matching, agent selection) and the daemon picks it up for execution in a sandboxed container.

### skip

The issue is not something the agent should work on. The triage agent adds `agent:skipped` and logs the reason. Triggers:

- Issue type is Epic
- Issue has subtasks (parent issues are not directly actionable)
- Issue is already in Done, Closed, or Resolved status
- All components are non-technical (documentation, marketing, legal, etc.)

## Integration with Dispatcher and Daemon

The triage agent integrates with the existing securetty dispatch chain:

```
jira-poller
    |
    v
jira-triage (classify)
    |
    +--> securetty dispatch "Implement Jira issue AAP-12345"
             |
             v
         dispatcher (queues job, matches skill)
             |
             v
         daemon (polls, executes in sandboxed container)
             |
             v
         agent session (code review, implementation, PR creation)
```

The `jira-triage` workflow definition (`workflows/jira-triage.yaml`) provides a three-stage DAG:

1. **classify** -- analyze the issue using `jira-query` skill
2. **act** -- perform the work using `code-review` skill
3. **report** -- update Jira with results using `jira-query` skill

This workflow can be triggered directly via the dispatcher API:

```bash
curl -X POST http://localhost:8900/workflows/run \
  -H "Content-Type: application/json" \
  -d '{"workflow":"jira-triage","work_item":"AAP-12345"}'
```

## Troubleshooting

### Poller is not picking up issues

1. Check that `SECURETTY_JIRA_URL` is set and reachable:
   ```bash
   curl -sf "$SECURETTY_JIRA_URL/rest/api/2/serverInfo" | python3 -m json.tool
   ```

2. Verify authentication works:
   ```bash
   curl -u "$SECURETTY_JIRA_USER:$JIRA_API_TOKEN" \
     "$SECURETTY_JIRA_URL/rest/api/2/myself"
   ```

3. Test the JQL query directly in Jira's issue search to confirm it returns results.

4. Check the log for errors:
   ```bash
   tail -50 ~/.securetty/jira-triage.log
   ```

### Issue was triaged but nothing happened

- Check that the dispatcher is running: `securetty daemon status`
- Check the dispatcher queue: `curl -sf http://localhost:8900/jobs?status=pending`
- Look for dispatch errors in the triage log: `grep "dispatch" ~/.securetty/jira-triage.log`

### Issue stuck with agent:needs-info

The reporter needs to update the issue with the requested information, then remove the `agent:needs-info` label. The next poll cycle will re-triage it.

### Wrong classification

Remove all `agent:*` labels from the issue in Jira to reset it. If the classification logic needs adjustment, edit the `_classify` function in `securetty-jira-triage.sh`.

### Poller won't start

- Check for a stale PID file: `cat ~/.securetty/jira-poller.pid`
- If the PID does not correspond to a running process, delete the file and try again:
  ```bash
  rm ~/.securetty/jira-poller.pid
  securetty jira-triage start
  ```

## Review Management

Once the triage agent dispatches a codeable issue and the agent creates an MR/PR, the issue enters the **review phase**. The review manager monitors merge request and pull request feedback, automatically responding to reviewer comments and driving issues to completion.

### The `agent:in-review` State

When the agent finishes implementation and pushes an MR/PR, the Jira label transitions from `agent:in-progress` to `agent:in-review`. This signals that the code is awaiting human review and the review manager should begin monitoring for feedback.

### How the Review Manager Works

The review manager polls GitLab MRs and GitHub PRs associated with in-review issues on a configurable interval (default: 120 seconds). When it detects new review feedback, it takes action based on the review state:

1. **Changes requested** -- The reviewer has posted comments or requested changes. The review manager feeds the feedback back to the agent, which re-implements the requested changes, force-pushes the updated branch, and returns the issue to `agent:in-review` status.

2. **Approval** -- The reviewer has approved the MR/PR. If `auto_merge` is enabled in configuration, the review manager merges the MR/PR automatically. The Jira label transitions from `agent:in-review` to `agent:completed`.

3. **Comments only** -- Informational comments without an explicit approval or change request. The review manager posts clarifying responses where appropriate.

### Feedback Cycle

The full feedback cycle operates as follows:

```
agent:in-progress (agent working)
        |
        v
   MR/PR created
        |
        v
   agent:in-review (awaiting human review)
        |
        +---> changes_requested
        |         |
        |         v
        |     agent re-implements changes
        |         |
        |         v
        |     force-push updated branch
        |         |
        |         +---> back to agent:in-review
        |
        +---> approved
                  |
                  v
             auto-merge (if enabled)
                  |
                  v
             agent:completed
```

### Stale Review Nudging

If an MR/PR has been in `agent:in-review` for longer than the configured threshold (default: 24 hours), the review manager posts a nudge comment on the MR/PR reminding reviewers that feedback is pending. This helps prevent issues from stalling in the review queue.

### Updated State Machine

With review management, the full label state machine becomes:

```
                    +------------------+
                    |   (no agent:*    |
                    |    label)        |
                    +--------+---------+
                             |
                        poller picks up
                             |
                             v
                    +------------------+
                    |  agent:triaged   |
                    +--------+---------+
                             |
                       classification
                      /      |       \
                     v       v        v
         +-----------+ +----------+ +-----------+
         | agent:    | | agent:   | | agent:    |
         | needs-info| |in-progress| | skipped  |
         +-----------+ +-----+----+ +-----------+
                             |
                        agent works
                             |
                             v
                    +------------------+
                    | agent:in-review  |<----+
                    +--------+---------+     |
                             |               |
                      review feedback        |
                      /             \        |
                     v               v       |
            +-------------+   +-----------+  |
            | changes     |   | approved  |  |
            | requested   |   +-----+-----+  |
            +------+------+         |         |
                   |                v         |
              re-implement    auto-merge      |
                   |          (if enabled)     |
                   |                |          |
                   +----------------+          |
                   |                           |
                   v (force-push)              |
                   +---------------------------+
                                    |
                                    v
                           +------------------+
                           |  agent:completed |
                           +------------------+
```

### CLI Usage

```bash
# Start the review manager
securetty review-manager start

# Check status
securetty review-manager status

# Stop the review manager
securetty review-manager stop
```

The review manager writes its PID to `~/.securetty/review-manager.pid` and logs to `~/.securetty/review-manager.log`.

### Configuration

The following settings in `group_vars/all.yml` control review management behavior:

| Setting | Default | Description |
|---------|---------|-------------|
| `review_poll_interval` | `120` | Seconds between review feedback polls |
| `auto_merge` | `false` | Automatically merge approved MRs/PRs |
| `stale_review_hours` | `24` | Hours before posting a stale-review nudge |

The `agent:in-review` label is configured alongside other triage labels in the `securetty_jira_triage.labels` section.
