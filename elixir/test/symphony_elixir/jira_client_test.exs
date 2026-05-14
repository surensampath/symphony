defmodule SymphonyElixir.JiraClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Adapter, as: JiraAdapter
  alias SymphonyElixir.Jira.Client, as: JiraClient

  defmodule FakeJiraClient do
    def fetch_candidate_issues, do: {:ok, [:candidate]}
    def fetch_issues_by_states(states), do: {:ok, states}
    def fetch_issue_states_by_ids(issue_ids), do: {:ok, issue_ids}
    def create_comment(issue_id, body), do: send(self(), {:comment, issue_id, body})
    def update_issue_state(issue_id, state_name), do: send(self(), {:state, issue_id, state_name})
  end

  test "tracker routes jira workflows to the jira adapter" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_api_token: "jira-token",
      tracker_project_slug: nil,
      tracker_project_key: "DEML"
    )

    assert Tracker.adapter() == SymphonyElixir.Jira.Adapter
  end

  test "jira adapter delegates tracker operations to configured jira client" do
    Application.put_env(:symphony_elixir, :jira_client_module, FakeJiraClient)

    assert JiraAdapter.fetch_candidate_issues() == {:ok, [:candidate]}
    assert JiraAdapter.fetch_issues_by_states(["To Do"]) == {:ok, ["To Do"]}
    assert JiraAdapter.fetch_issue_states_by_ids(["DEML-1"]) == {:ok, ["DEML-1"]}
    assert JiraAdapter.create_comment("DEML-1", "body") == {:comment, "DEML-1", "body"}
    assert JiraAdapter.update_issue_state("DEML-1", "In Progress") == {:state, "DEML-1", "In Progress"}
  end

  test "jira client normalizes REST issues to orchestrator issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://jira.example.test",
      tracker_api_token: "jira-token",
      tracker_project_slug: nil,
      tracker_project_key: "DEML"
    )

    issue =
      JiraClient.normalize_issue_for_test(%{
        "key" => "DEML-123",
        "fields" => %{
          "summary" => "Connect Jira",
          "description" => "Poll Jira tickets",
          "status" => %{"name" => "To Do"},
          "priority" => %{"id" => "2"},
          "labels" => ["Backend", "Jira"],
          "assignee" => %{"accountId" => "user-1", "emailAddress" => "dev@example.com"},
          "issuelinks" => [
            %{
              "type" => %{"name" => "Blocks"},
              "inwardIssue" => %{
                "key" => "DEML-111",
                "fields" => %{"status" => %{"name" => "In Progress"}}
              }
            }
          ],
          "created" => "2026-05-13T12:00:00.000+0000",
          "updated" => "2026-05-13T12:15:00.000+0000"
        }
      })

    assert issue.id == "DEML-123"
    assert issue.identifier == "DEML-123"
    assert issue.title == "Connect Jira"
    assert issue.description == "Poll Jira tickets"
    assert issue.state == "To Do"
    assert issue.priority == 2
    assert issue.labels == ["backend", "jira"]
    assert issue.assignee_id == "user-1"
    assert issue.url == "https://jira.example.test/browse/DEML-123"
    assert issue.blocked_by == [%{id: "DEML-111", identifier: "DEML-111", state: "In Progress"}]
    assert issue.assigned_to_worker
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at
  end
end
