---
tracker:
  kind: jira
  # Replace these placeholders with your Jira site and project details.
  endpoint: "https://jira.arm.com"
  api_key: "$JIRA_PERSONAL_TOKEN"
  project_key: "DEML"
  assignee: "Suren Sampath"
  active_states:
    - In Progress
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:Arm-Debug/edge-ai-sdk-research.git .
    if [ -f mix.exs ] && command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    if [ -f mix.exs ]; then
      mise exec -- mix workspace.before_remove
    fi
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Jira ticket `{{ issue.identifier }}` in read-only Jira mode.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
{% endif %}

Issue context:
Key: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. Jira is read-only for this workflow.
2. Do not transition Jira issues.
3. Do not add, edit, or reply to Jira comments.
4. Do not update Jira fields, labels, assignees, links, forms, worklogs, watchers, or attachments.
5. Do not create Jira issues.
6. You may read Jira issue content if tools are available, but never call Jira mutation tools.
7. Work only in the provided repository copy. Do not touch any other path.
8. Final message must report completed local actions and blockers only. Do not include next steps for the user.

Allowed Jira tools, if present:

- `jira_get_issue`
- `jira_search`
- `jira_get_transitions`
- `jira_get_issue_development_info`
- `jira_get_issues_development_info`

Forbidden Jira tools include, but are not limited to:

- `jira_add_comment`
- `jira_edit_comment`
- `jira_transition_issue`
- `jira_update_issue`
- `jira_create_issue`
- `jira_create_remote_issue_link`
- `jira_add_worklog`
- `jira_add_watcher`
- `jira_remove_watcher`
- `jira_update_proforma_form_answers`

Default posture:

- Treat the Jira issue as input only.
- Do not create a Jira workpad.
- Do not move the ticket to another status.
- Do not add PR links or status notes to Jira.
- If blocked, report the blocker in the final response only.
- If code changes are made locally, validate them locally and leave Jira untouched.
