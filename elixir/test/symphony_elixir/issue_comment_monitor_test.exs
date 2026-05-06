defmodule SymphonyElixir.IssueCommentMonitorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{IssueCommentMonitor, Linear.Issue, Workflow}

  defp setup_memory_tracker(issues, comments_by_issue) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_comments, comments_by_issue)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
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

  defp comment(overrides) do
    Map.merge(
      %{
        id: "c-1",
        body: "human feedback here",
        created_at: ~U[2026-05-06 10:00:00Z],
        updated_at: ~U[2026-05-06 10:00:00Z],
        parent_id: nil,
        author_id: "user-1",
        author_name: "kenta"
      },
      overrides
    )
  end

  test "first poll establishes baseline without routing" do
    setup_memory_tracker([human_pr_review_issue()], %{
      "issue-1" => [comment(%{id: "c-1"})]
    })

    state = IssueCommentMonitor.run_once_for_test(%{acted: %{}, baseline: %{}})

    refute_received {:memory_tracker_state_update, _, _}
    assert state.baseline["issue-1"].id == "c-1"
    assert is_nil(state.acted["issue-1"])
  end

  test "routes to Todo when a new actionable comment appears after baseline" do
    setup_memory_tracker([human_pr_review_issue()], %{
      "issue-1" => [
        comment(%{id: "c-1", updated_at: ~U[2026-05-06 10:00:00Z]}),
        comment(%{id: "c-2", body: "fix this please", updated_at: ~U[2026-05-06 11:00:00Z]})
      ]
    })

    initial_state = %{
      acted: %{},
      baseline: %{"issue-1" => %{id: "c-1", updated_at: ~U[2026-05-06 10:00:00Z]}}
    }

    new_state = IssueCommentMonitor.run_once_for_test(initial_state)

    assert_received {:memory_tracker_state_update, "issue-1", "Todo"}
    assert new_state.acted["issue-1"] == "c-2"
    assert new_state.baseline["issue-1"].id == "c-2"
  end

  test "is idempotent for the same comment across polls" do
    setup_memory_tracker([human_pr_review_issue()], %{
      "issue-1" => [
        comment(%{id: "c-1", updated_at: ~U[2026-05-06 10:00:00Z]}),
        comment(%{id: "c-2", body: "fix this please", updated_at: ~U[2026-05-06 11:00:00Z]})
      ]
    })

    initial_state = %{
      acted: %{},
      baseline: %{"issue-1" => %{id: "c-1", updated_at: ~U[2026-05-06 10:00:00Z]}}
    }

    state_after_first = IssueCommentMonitor.run_once_for_test(initial_state)
    assert_received {:memory_tracker_state_update, "issue-1", "Todo"}

    _ = IssueCommentMonitor.run_once_for_test(state_after_first)
    refute_received {:memory_tracker_state_update, "issue-1", _}
  end

  test "skips workpad and bot summary comments" do
    setup_memory_tracker([human_pr_review_issue()], %{
      "issue-1" => [
        comment(%{id: "c-old", updated_at: ~U[2026-05-06 09:00:00Z]}),
        comment(%{
          id: "c-workpad",
          body: "## Codex Workpad\n\nplan etc.",
          updated_at: ~U[2026-05-06 10:30:00Z]
        }),
        comment(%{
          id: "c-bot",
          body: "🐶 みらいいぬ自動調査 some report",
          updated_at: ~U[2026-05-06 10:45:00Z]
        })
      ]
    })

    initial_state = %{
      acted: %{},
      baseline: %{"issue-1" => %{id: "c-old", updated_at: ~U[2026-05-06 09:00:00Z]}}
    }

    _ = IssueCommentMonitor.run_once_for_test(initial_state)
    refute_received {:memory_tracker_state_update, "issue-1", _}
  end

  test "treats threaded replies as actionable triggers" do
    setup_memory_tracker([human_pr_review_issue()], %{
      "issue-1" => [
        comment(%{id: "c-old", updated_at: ~U[2026-05-06 09:00:00Z]}),
        comment(%{
          id: "c-reply",
          body: "ok thanks",
          parent_id: "c-old",
          updated_at: ~U[2026-05-06 11:00:00Z]
        })
      ]
    })

    initial_state = %{
      acted: %{},
      baseline: %{"issue-1" => %{id: "c-old", updated_at: ~U[2026-05-06 09:00:00Z]}}
    }

    new_state = IssueCommentMonitor.run_once_for_test(initial_state)
    assert_received {:memory_tracker_state_update, "issue-1", "Todo"}
    assert new_state.acted["issue-1"] == "c-reply"
  end

  test "skips Symphony cue comments so they don't re-trigger the monitor" do
    qa_issue = %Issue{
      id: "issue-qa",
      identifier: "GIKAI-700",
      title: "test",
      state: "QA",
      branch_name: "feature/gikai-700",
      url: "https://linear.app/team/issue/GIKAI-700"
    }

    setup_memory_tracker([qa_issue], %{
      "issue-qa" => [
        comment(%{id: "c-old", updated_at: ~U[2026-05-06 09:00:00Z]}),
        comment(%{
          id: "c-cue",
          body: "🐧 Symphony cue: 会話モード（`QA` から検知）\n\nこの cue 自身を再トリガしないように。",
          updated_at: ~U[2026-05-06 11:00:00Z]
        })
      ]
    })

    initial_state = %{
      acted: %{},
      baseline: %{"issue-qa" => %{id: "c-old", updated_at: ~U[2026-05-06 09:00:00Z]}}
    }

    _ = IssueCommentMonitor.run_once_for_test(initial_state)
    refute_received {:memory_tracker_state_update, _, _}
    refute_received {:memory_tracker_comment, _, _}
  end

  test "honors a custom target state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_pr_review_changes_requested_target_state: "Rework"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [human_pr_review_issue()])

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "issue-1" => [
        comment(%{id: "c-1", updated_at: ~U[2026-05-06 10:00:00Z]}),
        comment(%{id: "c-2", body: "redo", updated_at: ~U[2026-05-06 11:00:00Z]})
      ]
    })

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    initial_state = %{
      acted: %{},
      baseline: %{"issue-1" => %{id: "c-1", updated_at: ~U[2026-05-06 10:00:00Z]}}
    }

    _ = IssueCommentMonitor.run_once_for_test(initial_state)
    assert_received {:memory_tracker_state_update, "issue-1", "Rework"}
  end
end
