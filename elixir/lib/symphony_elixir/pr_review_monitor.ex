defmodule SymphonyElixir.PrReviewMonitor do
  @moduledoc """
  Polls GitHub for PR review state on Linear issues that are waiting in
  `Human PR Review`, and when a reviewer leaves a `CHANGES_REQUESTED`
  review, moves the issue back to the agent-active state so Symphony's
  PR feedback sweep picks it up automatically.

  Active when `tracker.github_repo` is set; otherwise the monitor is a
  no-op. Idempotent against repeated polls of the same review via an
  in-memory map keyed by issue id.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Tracker}

  @default_state %{acted: %{}}

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
        run_once(state, &fetch_pr_review_decision/2)
      rescue
        error ->
          Logger.warning("PrReviewMonitor poll crashed: #{Exception.message(error)}")
          state
      end

    schedule_check(current_interval_ms())
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Test surface

  @doc false
  @spec run_once_for_test(map(), (String.t(), String.t() -> {:ok, map()} | :no_pr | :error)) ::
          map()
  def run_once_for_test(state, fetch_fun) when is_map(state) and is_function(fetch_fun, 2) do
    run_once(state, fetch_fun)
  end

  # ---------------------------------------------------------------------------
  # Internals

  defp run_once(state, fetch_fun) do
    tracker = Config.settings!().tracker

    cond do
      not is_binary(tracker.github_repo) or tracker.github_repo == "" ->
        state

      true ->
        review_state = tracker.human_pr_review_state
        target_state = tracker.pr_review_changes_requested_target_state

        case Tracker.fetch_issues_by_states([review_state]) do
          {:ok, issues} ->
            Enum.reduce(issues, state, fn issue, acc ->
              check_issue(issue, tracker.github_repo, target_state, fetch_fun, acc)
            end)

          {:error, reason} ->
            Logger.debug("PrReviewMonitor skip cycle: #{inspect(reason)}")
            state
        end
    end
  end

  defp check_issue(%{branch_name: branch} = issue, repo, target_state, fetch_fun, state)
       when is_binary(branch) and branch != "" do
    case fetch_fun.(repo, branch) do
      {:ok, %{state: "CHANGES_REQUESTED", review_id: review_id}}
      when is_binary(review_id) ->
        already_acted = Map.get(state.acted, issue.id)

        cond do
          already_acted == review_id ->
            state

          true ->
            case Tracker.update_issue_state(issue.id, target_state) do
              :ok ->
                Logger.info(
                  "PrReviewMonitor routed CHANGES_REQUESTED PR to #{target_state} for issue=#{issue.identifier} review_id=#{review_id}"
                )

                put_in(state, [:acted, issue.id], review_id)

              {:error, reason} ->
                Logger.warning(
                  "PrReviewMonitor failed to route issue=#{issue.identifier}: #{inspect(reason)}"
                )

                state
            end
        end

      _ ->
        state
    end
  end

  defp check_issue(_issue, _repo, _target_state, _fetch_fun, state), do: state

  defp fetch_pr_review_decision(repo, branch_name) do
    with {:ok, pr_number} <- find_pr_number(repo, branch_name),
         {:ok, payload} <- pr_view_json(repo, pr_number) do
      decode_review_decision(payload)
    end
  end

  defp find_pr_number(repo, branch_name) do
    args = [
      "pr",
      "list",
      "--repo",
      repo,
      "--head",
      branch_name,
      "--state",
      "open",
      "--json",
      "number,headRefName"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, [%{"number" => number} | _]} when is_integer(number) -> {:ok, number}
          {:ok, _} -> :no_pr
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp pr_view_json(repo, pr_number) do
    args = [
      "pr",
      "view",
      to_string(pr_number),
      "--repo",
      repo,
      "--json",
      "reviewDecision,reviews"
    ]

    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> Jason.decode(output)
      _ -> :error
    end
  end

  defp decode_review_decision({:ok, payload}), do: decode_review_decision(payload)

  defp decode_review_decision(%{"reviewDecision" => "CHANGES_REQUESTED", "reviews" => reviews})
       when is_list(reviews) do
    case latest_changes_requested_review(reviews) do
      %{"id" => id} when is_binary(id) -> {:ok, %{state: "CHANGES_REQUESTED", review_id: id}}
      %{"id" => id} when is_integer(id) -> {:ok, %{state: "CHANGES_REQUESTED", review_id: to_string(id)}}
      _ -> :none
    end
  end

  defp decode_review_decision(%{}), do: :none
  defp decode_review_decision(_), do: :error

  defp latest_changes_requested_review(reviews) do
    reviews
    |> Enum.filter(&(&1["state"] == "CHANGES_REQUESTED"))
    |> Enum.sort_by(&(&1["submittedAt"] || ""), :desc)
    |> List.first()
  end

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check, interval_ms)
  end

  defp initial_interval_ms do
    # First check after a short delay so Linear/Tracker is ready.
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
