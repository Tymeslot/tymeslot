Code.require_file(
  "dev_support/credo_checks/no_inspect_in_logger_metadata.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.NoInspectInLoggerMetadataTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.NoInspectInLoggerMetadata

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp run_on(source, path \\ "lib/tymeslot/integrations/sync.ex") do
    source
    |> to_source_file(path)
    |> run_check(NoInspectInLoggerMetadata)
  end

  describe "flagged metadata" do
    test "flags inspect/1 as a keyword metadata value" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger

        def run(reason) do
          Logger.error("Sync failed", provider: :google, reason: inspect(reason))
        end
      end
      """
      |> run_on()
      |> assert_issue(fn issue ->
        assert issue.trigger == "inspect"
        assert issue.line_no == 5
        assert issue.message =~ "LogFormat.reason/1"
      end)
    end

    test "flags each inspect in a multi-line keyword list" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger

        def run(reason, state) do
          Logger.warning(
            "Sync failed",
            reason: inspect(reason),
            state: inspect(state, limit: 5)
          )
        end
      end
      """
      |> run_on()
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "flags Logger.log/3, Kernel.inspect, pipes, captures and interpolation" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger

        def run(reason, errors) do
          Logger.log(:error, "a", reason: inspect(reason))
          Logger.error("b", reason: Kernel.inspect(reason))
          Logger.error("c", reason: reason |> inspect())
          Logger.error("d", errors: Enum.map(errors, &inspect/1))
          Logger.error("e", reason: "failed: \#{inspect(reason)}")
        end
      end
      """
      |> run_on()
      |> assert_issues(fn issues -> assert length(issues) == 5 end)
    end

    test "flags inspect in a keyword list appended to a shared context" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger

        def run(log_context, reason) do
          Logger.error("Network error", log_context ++ [reason: inspect(reason)])
        end
      end
      """
      |> run_on()
      |> assert_issue()
    end
  end

  describe "accepted code" do
    test "accepts LogFormat.reason/1 and plain values" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger
        alias Tymeslot.Infrastructure.Logging.LogFormat

        def run(reason) do
          Logger.error("Sync failed", reason: LogFormat.reason(reason), attempt: 2)
        end
      end
      """
      |> run_on()
      |> refute_issues()
    end

    test "accepts inspect outside Logger metadata" do
      """
      defmodule Tymeslot.Integrations.Sync do
        require Logger

        def run(reason) do
          Logger.debug(fn -> inspect(reason) end)
          {:error, inspect(reason)}
        end
      end
      """
      |> run_on()
      |> refute_issues()
    end

    test "ignores files outside lib/" do
      """
      defmodule Tymeslot.Integrations.SyncTest do
        require Logger

        def run(reason), do: Logger.error("Sync failed", reason: inspect(reason))
      end
      """
      |> run_on("test/tymeslot/integrations/sync_test.exs")
      |> refute_issues()
    end
  end
end
