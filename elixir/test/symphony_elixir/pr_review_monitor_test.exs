defmodule SymphonyElixir.PrReviewMonitorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, PrReviewMonitor, Workflow}

  defp setup_memory_tracker(issues) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_github_repo: "team-mirai/mirai-gikai"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)
  end

  defp human_pr_review_issue(overrides \\ %{}) do
    base = %Issue{
      id: "issue-1",
      identifier: "GIKAI-298",
      title: "test",
      state: "Human PR Review",
      branch_name: "feature/gikai-298",
      url: "https://linear.app/team/issue/GIKAI-298"
    }

    Map.merge(base, overrides)
  end

  test "skips polling when github_repo is unset" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_github_repo: nil
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [human_pr_review_issue()])

    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)

    fetch_fun = fn _repo, _branch ->
      flunk("fetch_fun should not be called when github_repo is unset")
    end

    new_state = PrReviewMonitor.run_once_for_test(%{acted: %{}}, fetch_fun)
    assert new_state.acted == %{}
  end

  test "moves issue to Todo on fresh CHANGES_REQUESTED review" do
    setup_memory_tracker([human_pr_review_issue()])

    fetch_fun = fn "team-mirai/mirai-gikai", "feature/gikai-298" ->
      {:ok, %{kind: "review", id: "rev-100", author: "alice", timestamp: "2026-05-06T10:00:00Z"}}
    end

    new_state = PrReviewMonitor.run_once_for_test(%{acted: %{}}, fetch_fun)
    assert new_state.acted == %{"issue-1" => "review:rev-100"}

    assert_received {:memory_tracker_state_update, "issue-1", "Todo"}
  end

  test "moves issue to Todo on fresh top-level PR comment" do
    setup_memory_tracker([human_pr_review_issue()])

    fetch_fun = fn _repo, _branch ->
      {:ok, %{kind: "issue_comment", id: "c-42", author: "alice", timestamp: "2026-05-06T10:00:00Z"}}
    end

    new_state = PrReviewMonitor.run_once_for_test(%{acted: %{}}, fetch_fun)
    assert new_state.acted == %{"issue-1" => "issue_comment:c-42"}
    assert_received {:memory_tracker_state_update, "issue-1", "Todo"}
  end

  test "honors target_state override" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_github_repo: "team-mirai/mirai-gikai",
      tracker_pr_review_changes_requested_target_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [human_pr_review_issue()])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    fetch_fun = fn _repo, _branch ->
      {:ok, %{kind: "review", id: "rev-1", author: "alice", timestamp: "2026-05-06T10:00:00Z"}}
    end

    PrReviewMonitor.run_once_for_test(%{acted: %{}}, fetch_fun)
    assert_received {:memory_tracker_state_update, "issue-1", "Rework"}
  end

  test "is idempotent for the same signal across polls" do
    setup_memory_tracker([human_pr_review_issue()])

    fetch_fun = fn _repo, _branch ->
      {:ok, %{kind: "review", id: "rev-9", author: "alice", timestamp: "2026-05-06T10:00:00Z"}}
    end

    state_after_first = PrReviewMonitor.run_once_for_test(%{acted: %{}}, fetch_fun)
    assert_received {:memory_tracker_state_update, "issue-1", "Todo"}

    _ = PrReviewMonitor.run_once_for_test(state_after_first, fetch_fun)
    refute_received {:memory_tracker_state_update, "issue-1", _}
  end

  test "re-triggers when a new signal appears" do
    setup_memory_tracker([human_pr_review_issue()])

    state =
      %{acted: %{"issue-1" => "review:rev-9"}}
      |> PrReviewMonitor.run_once_for_test(fn _repo, _branch ->
        {:ok, %{kind: "review", id: "rev-10", author: "alice", timestamp: "2026-05-06T10:00:00Z"}}
      end)

    assert state.acted["issue-1"] == "review:rev-10"
    assert_received {:memory_tracker_state_update, "issue-1", "Todo"}
  end

  test "does not trigger when reviewDecision is APPROVED" do
    setup_memory_tracker([human_pr_review_issue()])

    fetch_fun = fn _repo, _branch -> :none end

    PrReviewMonitor.run_once_for_test(%{acted: %{}}, fetch_fun)
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "skips issues without a branch name" do
    setup_memory_tracker([human_pr_review_issue(%{branch_name: nil})])

    fetch_fun = fn _repo, _branch ->
      flunk("fetch_fun should not be called for branchless issues")
    end

    PrReviewMonitor.run_once_for_test(%{acted: %{}}, fetch_fun)
    refute_received {:memory_tracker_state_update, _, _}
  end
end
