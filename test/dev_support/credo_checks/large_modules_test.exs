Code.require_file(
  "dev_support/credo_checks/large_modules.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.LargeModulesTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.LargeModules
  alias Tymeslot.Precommit.Runner

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  # A module of exactly `lines` lines: `defmodule`, filler functions, `end`.
  defp module_of(lines) do
    body = Enum.map_join(1..(lines - 2), "\n", &"  def f#{&1}, do: #{&1}")

    "defmodule Tymeslot.Meetings do\n#{body}\nend"
    |> to_source_file("lib/tymeslot/meetings.ex")
  end

  defp run(lines),
    do: run_check(module_of(lines), LargeModules, max_lines: 10, hard_max_lines: 15)

  test "a module at the soft limit is not flagged" do
    10 |> run() |> refute_issues()
  end

  test "a module over the soft limit warns without failing the run" do
    run(11)
    |> assert_issue(fn issue ->
      assert issue.exit_status == 0
      assert issue.message =~ "Soft limit: `Tymeslot.Meetings` has 11 lines"
      assert issue.message =~ "(warns over 10, fails over 15)"
    end)
  end

  test "a module at the hard limit still only warns" do
    run(15) |> assert_issue(fn issue -> assert issue.exit_status == 0 end)
  end

  test "a module over the hard limit fails the run" do
    run(16)
    |> assert_issue(fn issue ->
      assert issue.exit_status == 2
      assert issue.message =~ "has 16 lines, which exceeds the hard limit of 15"
      refute issue.message =~ "Soft limit"
    end)
  end

  test "the defaults are 650 and 750" do
    module_of(651)
    |> run_check(LargeModules)
    |> assert_issue(fn issue -> assert issue.exit_status == 0 end)

    module_of(751)
    |> run_check(LargeModules)
    |> assert_issue(fn issue -> assert issue.exit_status == 2 end)
  end

  test "the precommit runner recognises the warning prefix" do
    assert Runner.warning_marker() == LargeModules.warning_prefix()
  end
end
