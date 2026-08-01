Code.require_file(
  "dev_support/credo_checks/no_unsafe_sanitize_merge.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoUnsafeSanitizeMergeTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoUnsafeSanitizeMerge

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged calls" do
    test "flags Map.merge(params, sanitized)" do
      """
      defmodule Tymeslot.Meetings do
        def build(params, sanitized) do
          Map.merge(params, sanitized)
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoUnsafeSanitizeMerge)
      |> assert_issue(fn issue -> assert issue.trigger == "Map.merge" end)
    end

    test "flags Map.merge(params, sanitized_params) via prefix match" do
      """
      defmodule Tymeslot.Meetings do
        def build(params, sanitized_params) do
          Map.merge(params, sanitized_params)
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoUnsafeSanitizeMerge)
      |> assert_issue(fn issue -> assert issue.trigger == "Map.merge" end)
    end

    test "flags Map.merge(params, selection) via named literal" do
      """
      defmodule Tymeslot.Meetings do
        def build(params, selection) do
          Map.merge(params, selection)
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoUnsafeSanitizeMerge)
      |> assert_issue(fn issue -> assert issue.trigger == "Map.merge" end)
    end

    test "flags the 3-argument form Map.merge(params, sanitized, resolver)" do
      """
      defmodule Tymeslot.Meetings do
        def build(params, sanitized, resolver) do
          Map.merge(params, sanitized, resolver)
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoUnsafeSanitizeMerge)
      |> assert_issue(fn issue -> assert issue.trigger == "Map.merge" end)
    end
  end

  describe "safe calls" do
    test "does not flag SanitizeMerge.merge(params, sanitized)" do
      """
      defmodule Tymeslot.Meetings do
        alias Tymeslot.Utils.SanitizeMerge

        def build(params, sanitized) do
          SanitizeMerge.merge(params, sanitized)
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoUnsafeSanitizeMerge)
      |> refute_issues()
    end

    test "does not flag Map.merge with an unrelated variable name" do
      """
      defmodule Tymeslot.Meetings do
        def build(params, defaults) do
          Map.merge(params, defaults)
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoUnsafeSanitizeMerge)
      |> refute_issues()
    end
  end

  describe "excluded files" do
    test "does not flag calls inside sanitize_merge.ex" do
      """
      defmodule Tymeslot.Utils.SanitizeMerge do
        def merge(left, sanitized) do
          Map.merge(left, sanitized)
        end
      end
      """
      |> to_source_file("lib/tymeslot/utils/sanitize_merge.ex")
      |> run_check(NoUnsafeSanitizeMerge)
      |> refute_issues()
    end

    test "does not flag calls inside sanitize_merge_test.exs" do
      """
      defmodule Tymeslot.Utils.SanitizeMergeTest do
        def example(params, sanitized) do
          Map.merge(params, sanitized)
        end
      end
      """
      |> to_source_file("test/tymeslot/utils/sanitize_merge_test.exs")
      |> run_check(NoUnsafeSanitizeMerge)
      |> refute_issues()
    end
  end
end
