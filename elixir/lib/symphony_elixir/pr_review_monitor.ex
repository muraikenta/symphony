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
  @spec run_once_for_test(map(), (String.t(), String.t() -> {:ok, map()} | :none | :no_pr | :error)) ::
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
      {:ok, %{kind: kind, id: signal_id} = signal} when is_binary(signal_id) ->
        signal_key = "#{kind}:#{signal_id}"
        already_acted = Map.get(state.acted, issue.id)

        if already_acted == signal_key do
          state
        else
          case Tracker.update_issue_state(issue.id, target_state) do
            :ok ->
              Logger.info(
                "PrReviewMonitor routed #{describe_signal(signal)} to #{target_state} for issue=#{issue.identifier}"
              )

              put_in(state, [:acted, issue.id], signal_key)

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

  defp describe_signal(%{kind: "review", id: id}),
    do: "CHANGES_REQUESTED review #{id}"

  defp describe_signal(%{kind: "issue_comment", id: id, author: author}),
    do: "PR comment #{id} by #{author}"

  defp describe_signal(%{kind: "review_comment", id: id, author: author}),
    do: "inline PR comment #{id} by #{author}"

  defp describe_signal(_), do: "PR signal"

  defp fetch_pr_review_decision(repo, branch_name) do
    with {:ok, pr_number} <- find_pr_number(repo, branch_name),
         {:ok, signals} <- collect_signals(repo, pr_number) do
      latest_actionable_signal(signals)
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

  defp collect_signals(repo, pr_number) do
    with {:ok, reviews} <- fetch_reviews(repo, pr_number),
         {:ok, issue_comments} <- fetch_issue_comments(repo, pr_number),
         {:ok, review_comments} <- fetch_review_comments(repo, pr_number) do
      {:ok,
       Enum.flat_map(reviews, &normalize_review/1) ++
         Enum.flat_map(issue_comments, &normalize_issue_comment/1) ++
         Enum.flat_map(review_comments, &normalize_review_comment/1)}
    end
  end

  defp fetch_reviews(repo, pr_number) do
    case System.cmd(
           "gh",
           ["api", "repos/#{repo}/pulls/#{pr_number}/reviews", "--paginate"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Jason.decode(output)
      _ -> :error
    end
  end

  defp fetch_issue_comments(repo, pr_number) do
    # Top-level PR comments (the conversation tab) live at /issues/<n>/comments.
    case System.cmd(
           "gh",
           ["api", "repos/#{repo}/issues/#{pr_number}/comments", "--paginate"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Jason.decode(output)
      _ -> :error
    end
  end

  defp fetch_review_comments(repo, pr_number) do
    # Inline review comments live at /pulls/<n>/comments.
    case System.cmd(
           "gh",
           ["api", "repos/#{repo}/pulls/#{pr_number}/comments", "--paginate"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Jason.decode(output)
      _ -> :error
    end
  end

  defp normalize_review(%{"state" => "CHANGES_REQUESTED"} = review) do
    author = get_in(review, ["user", "login"]) || ""
    id = id_to_string(review["id"])
    submitted_at = review["submitted_at"] || review["submittedAt"]

    if id && not bot?(author) do
      [%{kind: "review", id: id, author: author, timestamp: submitted_at}]
    else
      []
    end
  end

  defp normalize_review(_), do: []

  defp normalize_issue_comment(comment) do
    author = get_in(comment, ["user", "login"]) || ""
    id = id_to_string(comment["id"])
    created_at = comment["created_at"] || comment["createdAt"]

    if id && not bot?(author) do
      [%{kind: "issue_comment", id: id, author: author, timestamp: created_at}]
    else
      []
    end
  end

  defp normalize_review_comment(comment) do
    author = get_in(comment, ["user", "login"]) || ""
    id = id_to_string(comment["id"])
    created_at = comment["created_at"] || comment["createdAt"]

    if id && not bot?(author) do
      [%{kind: "review_comment", id: id, author: author, timestamp: created_at}]
    else
      []
    end
  end

  defp id_to_string(id) when is_integer(id), do: Integer.to_string(id)
  defp id_to_string(id) when is_binary(id) and id != "", do: id
  defp id_to_string(_), do: nil

  defp bot?(login) when is_binary(login), do: String.ends_with?(login, "[bot]")
  defp bot?(_), do: true

  defp latest_actionable_signal([]), do: :none

  defp latest_actionable_signal(signals) do
    case Enum.max_by(signals, &(&1.timestamp || ""), fn -> nil end) do
      nil -> :none
      signal -> {:ok, signal}
    end
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
