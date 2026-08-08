# Workload Identity Federation for CI/CD

How to replace static service account keys with Workload Identity Federation (WIF) when running securetty-based workloads (Claude Code via Vertex AI) in CI/CD pipelines.

## What WIF Is and Why It Matters

Workload Identity Federation lets external identities (GitHub Actions OIDC tokens, GitLab CI ID tokens) authenticate directly to Google Cloud without exporting service account key JSON files. Instead of storing a `GOOGLE_APPLICATION_CREDENTIALS_JSON` secret that never expires and can be exfiltrated, the CI runner presents a short-lived OIDC token that GCP validates against a configured identity provider.

**Before (service account key):**

```yaml
# ai-responder.yml -- current approach
- name: Setup Google Cloud credentials
  run: echo '${{ secrets.GOOGLE_APPLICATION_CREDENTIALS_JSON }}' > /tmp/gcloud-credentials.json
```

Problems with this approach:

- The key JSON never expires -- if leaked, it grants access until manually revoked
- The key must be stored as a GitHub/GitLab secret, broadening the blast radius
- Key rotation is manual and error-prone
- Violates least-privilege: the key works from any IP, any time

**After (WIF):**

- No long-lived credentials stored anywhere
- Tokens are scoped to a specific repo, branch, and workflow
- Tokens expire in minutes
- GCP audit logs show which CI job authenticated

## securetty Environment Variables

securetty uses these variables for Vertex AI access (defined in `group_vars/all.yml` under `securetty_vertex_vars`):

| Variable | Purpose | Example |
|----------|---------|---------|
| `CLAUDE_CODE_USE_VERTEX` | Enable Vertex AI backend for Claude Code | `1` |
| `ANTHROPIC_VERTEX_PROJECT_ID` | GCP project hosting the Vertex AI endpoint | `my-project-123456` |
| `GOOGLE_CLOUD_PROJECT` | GCP project for billing and resource management | `my-project-123456` |
| `GOOGLE_CLOUD_LOCATION` | GCP region for Vertex AI | `us-east5` |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | Block telemetry from Claude Code | `1` |

In CI/CD with WIF, you no longer need `GOOGLE_APPLICATION_CREDENTIALS` pointing to a key file. The `gcloud` auth from WIF sets up Application Default Credentials (ADC) automatically.

## GitHub Actions Setup

### 1. Create a WIF Pool and Provider in GCP

```bash
PROJECT_ID="your-gcp-project"
POOL_ID="github-actions-pool"
PROVIDER_ID="github-actions-provider"

# Create the workload identity pool
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="GitHub Actions Pool"

# Create the OIDC provider for GitHub
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --display-name="GitHub Actions Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner == 'dmzoneill'" \
  --issuer-uri="https://token.actions.githubusercontent.com"
```

The `--attribute-condition` restricts which GitHub orgs/users can authenticate. Tighten it further to specific repos:

```
--attribute-condition="assertion.repository == 'dmzoneill/securetty'"
```

### 2. Create a Service Account and Grant WIF Access

```bash
SA_NAME="github-actions-vertex"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Create the service account
gcloud iam service-accounts create "$SA_NAME" \
  --project="$PROJECT_ID" \
  --display-name="GitHub Actions Vertex AI"

# Grant Vertex AI user role
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user"

# Allow the WIF pool to impersonate this service account
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/dmzoneill/securetty"
```

### 3. GitHub Actions Workflow

Replace the current `ai-responder.yml` credential setup with WIF:

```yaml
name: AI Issue and PR Responder

on:
  issues:
    types: [opened]
  pull_request:
    types: [opened]

permissions:
  issues: write
  pull-requests: write
  id-token: write  # Required for WIF OIDC token
  contents: read

jobs:
  ai-respond:
    if: github.actor != 'dependabot[bot]'
    runs-on: ubuntu-latest

    steps:
      - name: Authenticate to Google Cloud via WIF
        uses: google-github-actions/auth@v2
        with:
          project_id: ${{ secrets.ANTHROPIC_VERTEX_PROJECT_ID }}
          workload_identity_provider: "projects/${{ secrets.GCP_PROJECT_NUMBER }}/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider"

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install Claude CLI
        run: npm install -g @anthropic-ai/claude-code

      - name: Install Python dependencies
        run: pip install requests

      - name: Download AI responder script
        run: |
          curl -sSL "https://raw.githubusercontent.com/dmzoneill/dmzoneill/main/ai-responder.py" -o ai-responder.py
          chmod +x ai-responder.py

      - name: Run AI responder
        env:
          ANTHROPIC_VERTEX_PROJECT_ID: ${{ secrets.ANTHROPIC_VERTEX_PROJECT_ID }}
          CLAUDE_CODE_USE_VERTEX: "1"
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GITHUB_REPOSITORY: ${{ github.repository }}
          ISSUE_NUMBER: ${{ github.event_name == 'issues' && github.event.issue.number || '' }}
          PR_NUMBER: ${{ github.event_name == 'pull_request' && github.event.pull_request.number || '' }}
          ISSUE_REPO_URL: "https://github.com/${{ github.repository }}"
          EVENT_TYPE: ${{ github.event_name == 'issues' && 'issue' || 'pull_request' }}
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_ISSUES_CHAT_ID: ${{ secrets.TELEGRAM_ISSUES_CHAT_ID }}
          TELEGRAM_PR_CHAT_ID: ${{ secrets.TELEGRAM_PR_CHAT_ID }}
        run: python ai-responder.py
```

Key changes from the current workflow:

- Added `id-token: write` permission (required for GitHub to issue OIDC tokens)
- Replaced the `echo credentials JSON to file` step with `google-github-actions/auth@v2`
- Removed `GOOGLE_APPLICATION_CREDENTIALS` env var (ADC is set up by the auth action)
- Added `GCP_PROJECT_NUMBER` secret (numeric project number, not the project ID)

### 4. GitHub Secrets Required

| Secret | Value | Notes |
|--------|-------|-------|
| `ANTHROPIC_VERTEX_PROJECT_ID` | `my-project-123456` | Already exists |
| `GCP_PROJECT_NUMBER` | `123456789012` | Numeric, find with `gcloud projects describe $PROJECT_ID --format='value(projectNumber)'` |

You can remove `GOOGLE_APPLICATION_CREDENTIALS_JSON` from secrets after migration.

## GitLab CI Setup

### 1. Create a WIF Pool and Provider for GitLab

```bash
PROJECT_ID="your-gcp-project"
POOL_ID="gitlab-ci-pool"
PROVIDER_ID="gitlab-ci-provider"
GITLAB_URL="https://gitlab.cee.redhat.com"  # or https://gitlab.com for public GitLab

# Create the workload identity pool
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="GitLab CI Pool"

# Create the OIDC provider for GitLab
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --display-name="GitLab CI Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.project_path=assertion.project_path,attribute.namespace_path=assertion.namespace_path,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.namespace_path.startsWith('your-group/')" \
  --issuer-uri="${GITLAB_URL}" \
  --allowed-audiences="${GITLAB_URL}"
```

For `gitlab.cee.redhat.com`, the issuer URI is the GitLab instance URL. For `gitlab.com`, use `https://gitlab.com`.

### 2. Grant WIF Access for GitLab

```bash
SA_NAME="gitlab-ci-vertex"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_NAME" \
  --project="$PROJECT_ID" \
  --display-name="GitLab CI Vertex AI"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user"

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')/locations/global/workloadIdentityPools/${POOL_ID}/attribute.project_path/your-group/your-project"
```

### 3. GitLab CI Pipeline

```yaml
stages:
  - respond

ai-respond:
  stage: respond
  image: node:20
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.cee.redhat.com  # Must match allowed-audiences in provider
  variables:
    GCP_PROJECT_ID: "your-gcp-project"
    GCP_PROJECT_NUMBER: "123456789012"
    GCP_POOL_ID: "gitlab-ci-pool"
    GCP_PROVIDER_ID: "gitlab-ci-provider"
    GCP_SA_EMAIL: "gitlab-ci-vertex@your-gcp-project.iam.gserviceaccount.com"
    GCP_REGION: "us-east5"
    ANTHROPIC_VERTEX_PROJECT_ID: "$GCP_PROJECT_ID"
    CLAUDE_CODE_USE_VERTEX: "1"
  before_script:
    # Install gcloud CLI
    - curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts
    - export PATH="$HOME/google-cloud-sdk/bin:$PATH"

    # Exchange GitLab OIDC token for GCP access token via WIF
    - |
      gcloud iam workload-identity-pools create-cred-config \
        "projects/${GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${GCP_POOL_ID}/providers/${GCP_PROVIDER_ID}" \
        --service-account="${GCP_SA_EMAIL}" \
        --output-file=/tmp/gcp-credentials.json \
        --credential-source-file=/tmp/gitlab-oidc-token \
        --credential-source-type=text
    - echo "$GITLAB_OIDC_TOKEN" > /tmp/gitlab-oidc-token
    - export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcp-credentials.json

    # Verify authentication works
    - gcloud auth login --cred-file=/tmp/gcp-credentials.json --quiet
    - gcloud auth application-default print-access-token --quiet > /dev/null
  script:
    - npm install -g @anthropic-ai/claude-code
    - pip install requests
    - python ai-responder.py
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

### GitLab CI Variables Required

Set these in GitLab CI/CD Settings > Variables:

| Variable | Value | Protected | Masked |
|----------|-------|-----------|--------|
| `GCP_PROJECT_NUMBER` | `123456789012` | Yes | Yes |
| `GCP_SA_EMAIL` | `gitlab-ci-vertex@project.iam.gserviceaccount.com` | Yes | No |

## ITPC (Identity Token Provider Client) -- Red Hat Internal

For Red Hat internal CI/CD environments using ITPC (the internal identity broker for GCP access), the setup differs from public GitHub/GitLab WIF.

### What ITPC Does

ITPC is Red Hat's internal service that brokers identity tokens for GCP access. Instead of configuring WIF pools directly in GCP, you register your CI/CD pipeline with ITPC, which manages the identity provider trust relationship centrally.

### Onboarding Steps

1. **Request ITPC access** -- File a ticket with the Cloud Infrastructure team requesting ITPC onboarding for your GCP project. Include:
   - GCP project ID
   - CI/CD platform (GitLab CE, Jenkins, Tekton)
   - Service account email that the workload will impersonate
   - Required IAM roles (e.g., `roles/aiplatform.user` for Vertex AI)

2. **Register your pipeline** -- Once approved, register your pipeline's OIDC issuer with ITPC:
   ```bash
   # ITPC CLI (available on internal toolbox images)
   itpc register \
     --project-id "$GCP_PROJECT_ID" \
     --issuer "https://gitlab.cee.redhat.com" \
     --subject "project_path:your-group/your-project:ref_type:branch:ref:main" \
     --service-account "$SA_EMAIL" \
     --roles "roles/aiplatform.user"
   ```

3. **Configure the pipeline** -- Use the ITPC credential helper in your CI job:
   ```yaml
   ai-respond:
     image: registry.redhat.io/rhel9/toolbox:latest
     id_tokens:
       ITPC_TOKEN:
         aud: https://itpc.corp.redhat.com
     variables:
       ANTHROPIC_VERTEX_PROJECT_ID: "your-gcp-project"
       CLAUDE_CODE_USE_VERTEX: "1"
       GOOGLE_CLOUD_LOCATION: "us-east5"
     before_script:
       - itpc auth --token="$ITPC_TOKEN" --project="$ANTHROPIC_VERTEX_PROJECT_ID"
       - export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/application_default_credentials.json"
     script:
       - npm install -g @anthropic-ai/claude-code
       - claude --version
   ```

4. **Verify in staging first** -- ITPC provides a staging endpoint. Test your pipeline against `itpc-stage.corp.redhat.com` before going to production.

5. **Rotate the ITPC registration** -- ITPC registrations expire after 12 months. Set a calendar reminder to renew.

### ITPC vs Direct WIF

| Aspect | Direct WIF | ITPC |
|--------|-----------|------|
| Pool/provider management | You manage in GCP | Centrally managed by Cloud Infra |
| Issuer trust | You configure | Pre-configured for internal GitLab |
| Audit trail | GCP audit logs only | ITPC logs + GCP audit logs |
| Approval process | Self-service | Ticket-based (24h SLA) |
| Use case | Public GitHub repos | Internal GitLab CI/CD |

## How securetty Uses These Variables at Runtime

For local development, securetty's `generate-env.sh` discovers Vertex variables from the host environment and writes them into per-service `.env` files:

- **Dev container** gets the full `.env` (all Vertex vars)
- **OmniRoute** gets `.env.omniroute` (includes `CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_VERTEX_PROJECT_ID`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`)
- **CloudCLI** gets `.env.cloudcli` (Vertex vars + `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`)

The gcloud ADC credentials directory (`~/.config/gcloud`) is bind-mounted into containers (see `podman-compose.yml` line 69), so WIF-obtained credentials on the host propagate into containers automatically.

In CI/CD, these same variables are set as workflow environment variables. The `google-github-actions/auth@v2` action (or GitLab's `gcloud auth login --cred-file`) sets up ADC so that Claude Code's Vertex AI backend can authenticate without explicit credential paths.

## Troubleshooting

### `PERMISSION_DENIED: The caller does not have permission`

The WIF principal does not have `roles/iam.workloadIdentityUser` on the target service account, or the attribute condition does not match.

```bash
# Check the IAM policy on the service account
gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --format=json

# Verify the principal format matches your CI platform
# GitHub: principalSet://...attribute.repository/org/repo
# GitLab: principalSet://...attribute.project_path/group/project
```

### `INVALID_ARGUMENT: The audience in the token does not match`

The `aud` claim in the OIDC token does not match the `--allowed-audiences` in the WIF provider.

For GitLab, ensure `id_tokens.GITLAB_OIDC_TOKEN.aud` matches the `--allowed-audiences` flag. For GitHub Actions, the `google-github-actions/auth` action handles this automatically.

```bash
# Check what audience the provider expects
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --format="value(oidc.allowedAudiences)"
```

### `NOT_FOUND: Workload identity pool not found`

The `GCP_PROJECT_NUMBER` is wrong, or the pool/provider IDs are misspelled.

```bash
# Get the correct project number
gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)'

# List existing pools
gcloud iam workload-identity-pools list \
  --project="$PROJECT_ID" \
  --location="global"
```

### `Error: Unable to detect a default project`

`GOOGLE_CLOUD_PROJECT` or `ANTHROPIC_VERTEX_PROJECT_ID` is not set. In GitHub Actions:

```yaml
env:
  GOOGLE_CLOUD_PROJECT: ${{ secrets.ANTHROPIC_VERTEX_PROJECT_ID }}
  ANTHROPIC_VERTEX_PROJECT_ID: ${{ secrets.ANTHROPIC_VERTEX_PROJECT_ID }}
```

### `Could not load the default credentials`

ADC is not configured. The `google-github-actions/auth@v2` action sets `GOOGLE_APPLICATION_CREDENTIALS` automatically. If using a custom setup, verify:

```bash
# Check ADC is available
gcloud auth application-default print-access-token 2>&1

# Check the credentials file exists
ls -la "$GOOGLE_APPLICATION_CREDENTIALS"
```

### `Token exchange failed` (GitLab OIDC)

The credential source file does not contain the OIDC token. Ensure the token file is written before `gcloud` reads it:

```yaml
# Write token BEFORE creating cred config
- echo "$GITLAB_OIDC_TOKEN" > /tmp/gitlab-oidc-token
- gcloud iam workload-identity-pools create-cred-config ... \
    --credential-source-file=/tmp/gitlab-oidc-token
```

### `Vertex AI API has not been enabled`

The Vertex AI API must be enabled in the GCP project:

```bash
gcloud services enable aiplatform.googleapis.com --project="$PROJECT_ID"
```

### WIF works but Claude Code returns `401 Unauthorized`

The service account has WIF access but lacks the Vertex AI IAM role:

```bash
# Grant the Vertex AI user role
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user"

# For Claude Code specifically, you may also need:
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/serviceusage.serviceUsageConsumer"
```

## Migration Checklist

- [ ] Create WIF pool and OIDC provider in GCP
- [ ] Create a dedicated service account with `roles/aiplatform.user`
- [ ] Bind the WIF principal to the service account
- [ ] Add `id-token: write` permission to GitHub Actions workflow
- [ ] Replace `google-application-credentials` step with `google-github-actions/auth@v2`
- [ ] Remove `GOOGLE_APPLICATION_CREDENTIALS` env var from workflow
- [ ] Add `GCP_PROJECT_NUMBER` to repository secrets
- [ ] Test the workflow on a PR branch before merging
- [ ] Delete `GOOGLE_APPLICATION_CREDENTIALS_JSON` from repository secrets
- [ ] Update `securetty_allowed_domains` in `group_vars/all.yml` if new GCP endpoints are needed
