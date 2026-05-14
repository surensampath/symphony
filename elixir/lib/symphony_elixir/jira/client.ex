defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira REST client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @issue_fields "summary,description,status,priority,labels,assignee,issuelinks,created,updated"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_settings(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      fetch_by_jql(candidate_jql(tracker), assignee_filter)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_tracker_settings(tracker) do
        fetch_by_jql(project_states_jql(tracker.project_key, normalized_states), nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_keys =
      issue_ids
      |> Enum.map(&normalize_non_empty_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case issue_keys do
      [] ->
        {:ok, []}

      issue_keys ->
        with :ok <- validate_tracker_settings(Config.settings!().tracker),
             {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, issues} <- fetch_by_jql(issue_keys_jql(issue_keys), assignee_filter) do
          {:ok, sort_issues_by_requested_ids(issues, issue_order_index(issue_keys))}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case request(:post, "/rest/api/2/issue/#{encode_path_segment(issue_id)}/comment", json: %{"body" => body}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, response} -> jira_status_error("comment create", response)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, transition_id} <- resolve_transition_id(issue_id, state_name),
         {:ok, %{status: status}} when status in 200..299 <-
           request(:post, "/rest/api/2/issue/#{encode_path_segment(issue_id)}/transitions", json: %{"transition" => %{"id" => transition_id}}) do
      :ok
    else
      {:ok, response} -> jira_status_error("transition issue", response)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue), do: normalize_issue(issue, nil)

  defp fetch_by_jql(jql, assignee_filter) when is_binary(jql) do
    do_fetch_by_jql(jql, assignee_filter, 0, [])
  end

  defp do_fetch_by_jql(jql, assignee_filter, start_at, acc_issues) do
    params = %{
      "jql" => jql,
      "fields" => @issue_fields,
      "maxResults" => @issue_page_size,
      "startAt" => start_at
    }

    with {:ok, %{status: 200, body: body}} <- request(:get, "/rest/api/2/search", params: params),
         {:ok, issues, total, returned_count} <- decode_search_response(body, assignee_filter) do
      updated_acc = Enum.reverse(issues, acc_issues)
      next_start = start_at + returned_count

      if returned_count > 0 and next_start < total do
        do_fetch_by_jql(jql, assignee_filter, next_start, updated_acc)
      else
        {:ok, Enum.reverse(updated_acc)}
      end
    else
      {:ok, response} -> jira_status_error("search", response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_search_response(%{"issues" => issues} = body, assignee_filter) when is_list(issues) do
    normalized_issues =
      issues
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    {:ok, normalized_issues, parse_count(body["total"]), length(issues)}
  end

  defp decode_search_response(%{"errorMessages" => messages}, _assignee_filter) do
    {:error, {:jira_errors, messages}}
  end

  defp decode_search_response(_unknown, _assignee_filter), do: {:error, :jira_unknown_payload}

  defp resolve_transition_id(issue_id, state_name) do
    case request(:get, "/rest/api/2/issue/#{encode_path_segment(issue_id)}/transitions") do
      {:ok, %{status: 200, body: %{"transitions" => transitions}}} when is_list(transitions) ->
        extract_transition_id(transitions, state_name)

      {:ok, response} ->
        jira_status_error("list transitions", response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_transition_id(transitions, state_name) when is_list(transitions) do
    transition_id =
      Enum.find_value(transitions, fn transition ->
        if transition_matches_state?(transition, state_name), do: transition["id"]
      end)

    case transition_id do
      transition_id when is_binary(transition_id) -> {:ok, transition_id}
      _ -> {:error, :transition_not_found}
    end
  end

  defp transition_matches_state?(%{"name" => name}, state_name) when is_binary(name) do
    normalize_state_name(name) == normalize_state_name(state_name)
  end

  defp transition_matches_state?(%{"to" => %{"name" => name}}, state_name) when is_binary(name) do
    normalize_state_name(name) == normalize_state_name(state_name)
  end

  defp transition_matches_state?(_transition, _state_name), do: false

  defp candidate_jql(tracker) do
    project_states_jql(tracker.project_key, tracker.active_states)
    |> maybe_append_assignee_clause(tracker.assignee)
    |> Kernel.<>(" ORDER BY priority ASC, created ASC")
  end

  defp project_states_jql(project_key, state_names) do
    "project = #{jql_string(project_key)} AND status in (#{Enum.map_join(state_names, ", ", &jql_string/1)})"
  end

  defp issue_keys_jql(issue_keys) do
    "issuekey in (#{Enum.map_join(issue_keys, ", ", &jql_string/1)})"
  end

  defp maybe_append_assignee_clause(jql, nil), do: jql

  defp maybe_append_assignee_clause(jql, assignee) when is_binary(assignee) do
    case String.trim(assignee) do
      "" -> jql
      "me" -> jql <> " AND assignee = currentUser()"
      value -> jql <> " AND assignee = #{jql_string(value)}"
    end
  end

  defp jql_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp request(method, path, opts \\ []) when method in [:get, :post] and is_binary(path) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_settings(tracker),
         {:ok, headers} <- rest_headers(tracker.api_key) do
      Req.request(
        Keyword.merge(opts,
          method: method,
          url: endpoint_url(tracker.endpoint, path),
          headers: headers,
          connect_options: [timeout: 30_000]
        )
      )
    end
  end

  defp endpoint_url(endpoint, path) do
    String.trim_trailing(endpoint, "/") <> path
  end

  defp rest_headers(api_key) when is_binary(api_key) do
    {:ok,
     [
       {"Authorization", authorization_header(api_key)},
       {"Accept", "application/json"},
       {"Content-Type", "application/json"}
     ]}
  end

  defp rest_headers(_api_key), do: {:error, :missing_jira_api_token}

  defp authorization_header(api_key) do
    trimmed = String.trim(api_key)

    if String.match?(trimmed, ~r/^(Bearer|Basic)\s+/i) do
      trimmed
    else
      "Bearer " <> trimmed
    end
  end

  defp validate_tracker_settings(tracker) do
    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_jira_api_token}
      not is_binary(tracker.endpoint) -> {:error, :missing_jira_endpoint}
      not is_binary(tracker.project_key) -> {:error, :missing_jira_project_key}
      true -> :ok
    end
  end

  defp normalize_issue(%{"key" => key, "fields" => fields}, assignee_filter)
       when is_binary(key) and is_map(fields) do
    assignee = fields["assignee"]

    %Issue{
      id: key,
      identifier: key,
      title: fields["summary"],
      description: normalize_description(fields["description"]),
      priority: parse_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: String.downcase(key),
      url: issue_url(key),
      assignee_id: assignee_identity(assignee),
      blocked_by: extract_blockers(fields),
      labels: extract_labels(fields),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp issue_url(key) when is_binary(key) do
    Config.settings!().tracker.endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>("/browse/#{key}")
  end

  defp normalize_description(nil), do: nil
  defp normalize_description(description) when is_binary(description), do: description

  defp normalize_description(description) do
    case Jason.encode(description) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(description)
    end
  end

  defp assignee_identity(%{} = assignee) do
    Enum.find_value(["accountId", "name", "emailAddress", "displayName"], &normalize_non_empty_string(assignee[&1]))
  end

  defp assignee_identity(_assignee), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_match_values()
    |> Enum.any?(&MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_match_values(%{} = assignee) do
    ["accountId", "name", "emailAddress", "displayName"]
    |> Enum.map(&normalize_assignee_match_value(assignee[&1]))
    |> Enum.reject(&is_nil/1)
  end

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        {:ok, nil}

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp normalize_non_empty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_non_empty_string(_value), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(&normalize_non_empty_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_fields), do: []

  defp extract_blockers(%{"issuelinks" => issue_links}) when is_list(issue_links) do
    Enum.flat_map(issue_links, fn
      %{"type" => %{"name" => type_name}, "inwardIssue" => blocker_issue}
      when is_binary(type_name) and is_map(blocker_issue) ->
        if String.downcase(type_name) == "blocks", do: [linked_issue_blocker(blocker_issue)], else: []

      _link ->
        []
    end)
  end

  defp extract_blockers(_fields), do: []

  defp linked_issue_blocker(%{"key" => key, "fields" => fields}) when is_map(fields) do
    %{id: key, identifier: key, state: get_in(fields, ["status", "name"])}
  end

  defp linked_issue_blocker(%{"key" => key}), do: %{id: key, identifier: key, state: nil}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp parse_priority(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {priority, ""} -> priority
      _ -> nil
    end
  end

  defp parse_priority(%{"name" => "Highest"}), do: 1
  defp parse_priority(%{"name" => "High"}), do: 2
  defp parse_priority(%{"name" => "Medium"}), do: 3
  defp parse_priority(%{"name" => "Low"}), do: 4
  defp parse_priority(_priority), do: nil

  defp parse_count(count) when is_integer(count), do: count
  defp parse_count(_count), do: 0

  defp issue_order_index(issue_keys) when is_list(issue_keys) do
    issue_keys
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp encode_path_segment(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name |> String.trim() |> String.downcase()
  end

  defp jira_status_error(operation, response) do
    Logger.error("Jira REST #{operation} failed status=#{response.status} body=#{summarize_error_body(response.body)}")
    {:error, {:jira_api_status, response.status}}
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
