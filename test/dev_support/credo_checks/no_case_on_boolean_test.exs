Code.require_file(
  "dev_support/credo_checks/no_case_on_boolean.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoCaseOnBooleanTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoCaseOnBoolean

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags a case with only true and false clauses" do
      """
      defmodule Tymeslot.Meetings do
        def start(enabled?) do
          case enabled? do
            true -> :started
            false -> :ok
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoCaseOnBoolean)
      |> assert_issue(fn issue -> assert issue.trigger == "case" end)
    end

    test "flags regardless of clause order" do
      """
      defmodule Tymeslot.Meetings do
        def start(enabled?) do
          case enabled? do
            false -> :ok
            true -> :started
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoCaseOnBoolean)
      |> assert_issue()
    end
  end

  describe "accepted cases" do
    test "accepts a case with a catch-all third clause" do
      """
      defmodule Tymeslot.Meetings do
        def start(value) do
          case value do
            true -> :started
            false -> :ok
            other -> {:error, other}
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoCaseOnBoolean)
      |> refute_issues()
    end

    test "accepts a case on tagged tuples" do
      """
      defmodule Tymeslot.Meetings do
        def start(result) do
          case result do
            {:ok, meeting} -> meeting
            {:error, reason} -> reason
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoCaseOnBoolean)
      |> refute_issues()
    end

    test "accepts a case mixing a boolean with a non-boolean clause" do
      """
      defmodule Tymeslot.Meetings do
        def start(value) do
          case value do
            true -> :started
            nil -> :ok
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/meetings.ex")
      |> run_check(NoCaseOnBoolean)
      |> refute_issues()
    end
  end
end
