defmodule SymphonyElixir.IssueCommentMonitor do
  @moduledoc """
  Polls Linear for new comments on issues that are sitting in the
  `Human PR Review` state. When the human leaves a fresh comment that
  is not the agent's own workpad or a known bot summary, the monitor
  routes the issue back to the configured active state (default
  `Todo`) so Symphony's normal poll loop can pick it up and run the
  PR feedback sweep.

  This complements `PrReviewMonitor` for cases where the human cannot
  use a GitHub `Request changes` review (e.g., they authored the PR
  themselves) and instead leaves feedback as a Linear comment.

  Active when `tracker.github_repo` is set OR when the issue scope
  itself indicates Symphony is in charge — for now we gate on the
  presence of `tracker.team_key` or `tracker.project_slug` which are
  required for any Symphony deployment.

  Idempotency: tracks the latest acted comment id per issue in
  process state so we don't re-trigger on the same feedback.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Orchestrator, Tracker}

  @default_state %{acted: %{}, baseline: %{}}

  @workpad_marker "## Codex Workpad"
  @cue_marker "🐧 Symphony cue:"
  @bot_summary_markers [
    "🐶 みらいいぬ自動調査",
    "🤖 Codex"
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    schedule_check(initial_interval_ms())
    {:ok, @default_state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state =
      try do
        run_once(state)
      rescue
        error ->
          Logger.warning("IssueCommentMonitor poll crashed: #{Exception.message(error)}")
          state
      end

    schedule_check(current_interval_ms())
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Test surface

  @doc false
  @spec run_once_for_test(map()) :: map()
  def run_once_for_test(state) when is_map(state) do
    run_once(state)
  end

  # ---------------------------------------------------------------------------
  # Internals

  defp run_once(state) do
    tracker = Config.settings!().tracker
    review_state = tracker.human_pr_review_state
    conversational_states = List.wrap(tracker.conversational_states) |> Enum.filter(&is_binary/1)
    target_state = tracker.pr_review_changes_requested_target_state
    monitored_states = Enum.uniq([review_state | conversational_states] |> Enum.filter(&is_binary/1))

    case Tracker.fetch_issues_by_states(monitored_states) do
      {:ok, issues} ->
        Enum.reduce(issues, state, fn issue, acc ->
          mode = classify_mode(issue, review_state, conversational_states)
          check_issue(issue, mode, target_state, acc)
        end)

      {:error, reason} ->
        Logger.debug("IssueCommentMonitor skip cycle: #{inspect(reason)}")
        state
    end
  end

  defp classify_mode(issue, review_state, conversational_states) do
    cond do
      issue.state == review_state -> :feedback
      issue.state in conversational_states -> {:conversational, issue.state}
      true -> :unknown
    end
  end

  defp check_issue(%{id: issue_id} = issue, mode, target_state, state)
       when is_binary(issue_id) and mode != :unknown do
    case Tracker.fetch_issue_comments(issue_id) do
      {:ok, comments} ->
        actionable = filter_actionable(comments)
        latest = latest_comment(actionable)

        cond do
          # First time we see this issue: record the current latest as the
          # baseline so we don't trigger on pre-existing feedback we missed
          # before startup. Also seed acted with the latest so a redo of an
          # already-handled comment is not re-triggered after restart.
          not Map.has_key?(state.baseline, issue_id) ->
            seed_baseline(state, issue_id, latest)

          # No actionable comments at all yet, nothing to do.
          is_nil(latest) ->
            state

          # Already acted on this exact comment.
          Map.get(state.acted, issue_id) == latest.id ->
            state

          # Already at-or-before the baseline; user has not added a new
          # human comment since the issue entered the monitored state.
          baseline_covers?(state.baseline[issue_id], latest) ->
            state

          true ->
            attempt_route(issue, latest, mode, target_state, state)
        end

      {:error, reason} ->
        Logger.debug("IssueCommentMonitor failed to fetch comments for #{issue_id}: #{inspect(reason)}")
        state
    end
  end

  defp check_issue(_issue, _mode, _target_state, state), do: state

  defp seed_baseline(state, issue_id, latest) do
    baseline =
      case latest do
        %{id: id, updated_at: updated_at} when is_binary(id) ->
          %{id: id, updated_at: updated_at}

        _ ->
          %{id: nil, updated_at: nil}
      end

    %{state | baseline: Map.put(state.baseline, issue_id, baseline)}
  end

  defp baseline_covers?(%{id: baseline_id, updated_at: baseline_at}, %{
         id: latest_id,
         updated_at: latest_at
       }) do
    cond do
      baseline_id == latest_id ->
        true

      is_nil(baseline_at) or is_nil(latest_at) ->
        false

      true ->
        DateTime.compare(latest_at, baseline_at) != :gt
    end
  end

  defp baseline_covers?(_baseline, _latest), do: false

  defp attempt_route(%{id: issue_id, identifier: identifier} = _issue, latest, :feedback, target_state, state) do
    case Tracker.update_issue_state(issue_id, target_state) do
      :ok ->
        Logger.info(
          "IssueCommentMonitor routed new comment to #{target_state} (feedback) for issue=#{identifier} comment_id=#{latest.id}"
        )

        record_acted(state, issue_id, latest)

      {:error, reason} ->
        Logger.warning(
          "IssueCommentMonitor failed to route issue=#{identifier}: #{inspect(reason)}"
        )

        state
    end
  end

  defp attempt_route(
         %{id: issue_id, identifier: identifier} = issue,
         latest,
         {:conversational, original_state},
         _target_state,
         state
       ) do
    Orchestrator.request_dispatch(issue)

    Logger.info(
      "IssueCommentMonitor dispatched conversational agent (state=#{original_state}) for issue=#{identifier} comment_id=#{latest.id}"
    )

    record_acted(state, issue_id, latest)
  end

  defp record_acted(state, issue_id, latest) do
    %{
      state
      | acted: Map.put(state.acted, issue_id, latest.id),
        baseline: Map.put(state.baseline, issue_id, %{id: latest.id, updated_at: latest.updated_at})
    }
  end

  defp filter_actionable(comments) do
    # Top-level comments AND thread replies both qualify as triggers; only
    # the agent's own workpad/cue and known bot summaries are excluded.
    comments
    |> Enum.reject(&workpad?/1)
    |> Enum.reject(&symphony_cue?/1)
    |> Enum.reject(&bot_summary?/1)
  end

  defp workpad?(%{body: body}) when is_binary(body), do: String.starts_with?(body, @workpad_marker)
  defp workpad?(_), do: false

  defp symphony_cue?(%{body: body}) when is_binary(body), do: String.contains?(body, @cue_marker)
  defp symphony_cue?(_), do: false

  defp bot_summary?(%{body: body}) when is_binary(body) do
    Enum.any?(@bot_summary_markers, &String.contains?(body, &1))
  end

  defp bot_summary?(_), do: false

  defp latest_comment([]), do: nil

  defp latest_comment(comments) do
    Enum.max_by(comments, &updated_at_for_sort/1, fn -> nil end)
  end

  defp updated_at_for_sort(%{updated_at: %DateTime{} = ts}), do: DateTime.to_unix(ts, :microsecond)
  defp updated_at_for_sort(%{created_at: %DateTime{} = ts}), do: DateTime.to_unix(ts, :microsecond)
  defp updated_at_for_sort(_), do: 0

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check, interval_ms)
  end

  defp initial_interval_ms do
    min(current_interval_ms(), 5_000)
  end

  defp current_interval_ms do
    case Config.settings() do
      {:ok, settings} ->
        case settings.tracker.pr_review_polling_interval_ms do
          ms when is_integer(ms) and ms > 0 -> ms
          _ -> 30_000
        end

      _ ->
        30_000
    end
  end
end
