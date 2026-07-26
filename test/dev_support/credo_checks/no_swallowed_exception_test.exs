Code.require_file(
  "dev_support/credo_checks/no_swallowed_exception.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoSwallowedExceptionTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoSwallowedException

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged rescues" do
    test "flags a rescue that returns nil" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            _error -> nil
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> assert_issue(fn issue -> assert issue.trigger == "rescue" end)
    end

    test "flags a rescue that returns a tagged error without logging" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            _error -> {:error, :sync_failed}
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> assert_issue()
    end

    test "flags a def-level rescue" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          fetch()
        rescue
          _error -> :error
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> assert_issue()
    end

    test "flags a defp-level rescue" do
      """
      defmodule Tymeslot.Integrations.Sync do
        defp run do
          fetch()
        rescue
          _error -> :error
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> assert_issue()
    end

    test "flags the swallowing clause in a multi-clause rescue" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger

        def run do
          try do
            fetch()
          rescue
            error in [ArgumentError] ->
              Logger.warning("bad args", error: inspect(error))
              {:error, :bad_args}

            _error ->
              :error
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> assert_issue(fn issue -> assert issue.line_no == 12 end)
    end
  end

  describe "accepted rescues" do
    test "accepts a rescue that logs" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger

        def run do
          try do
            fetch()
          rescue
            error ->
              Logger.warning("sync failed", error: inspect(error))
              {:error, :sync_failed}
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end

    test "accepts a rescue that re-raises" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            error -> reraise(error, __STACKTRACE__)
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end

    test "accepts a rescue that raises a new exception" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            _error -> raise "sync failed"
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end

    test "accepts a rescue that throws" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            _error -> throw(:sync_failed)
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end

    test "accepts a rescue that exits" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            _error -> exit(:sync_failed)
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end

    test "accepts a rescue that passes the exception binding to a helper" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            error -> handle_integration_error(error, :provider)
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end

    test "accepts a rescue that re-raises via the remote Kernel.reraise/2 form" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          try do
            fetch()
          rescue
            error -> Kernel.reraise(error, __STACKTRACE__)
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end

    test "accepts code with no rescue at all" do
      """
      defmodule Tymeslot.Integrations.Sync do
        def run do
          case fetch() do
            {:ok, result} -> result
            {:error, reason} -> {:error, reason}
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot/integrations/sync.ex")
      |> run_check(NoSwallowedException)
      |> refute_issues()
    end
  end
end
