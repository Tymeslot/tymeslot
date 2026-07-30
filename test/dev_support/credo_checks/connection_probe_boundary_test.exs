Code.require_file(
  "dev_support/credo_checks/connection_probe_boundary.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.ConnectionProbeBoundaryTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.ConnectionProbeBoundary

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "allowed files" do
    test "no issues inside calendar/connection.ex" do
      """
      defmodule Tymeslot.Integrations.Calendar.Connection do
        def probe(provider_module, config), do: provider_module.perform_connection_test(config)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar/connection.ex")
      |> run_check(ConnectionProbeBoundary)
      |> refute_issues()
    end

    test "no issues inside video/providers/provider_registry.ex" do
      """
      defmodule Tymeslot.Integrations.Video.Providers.ProviderRegistry do
        def test_provider_connection(module, config), do: module.perform_connection_test(config)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/video/providers/provider_registry.ex")
      |> run_check(ConnectionProbeBoundary)
      |> refute_issues()
    end

    test "no issues for test files" do
      """
      defmodule Tymeslot.SomeTest do
        def call(module, config), do: module.perform_connection_test(config)
      end
      """
      |> to_source_file("test/tymeslot/some_test.exs")
      |> run_check(ConnectionProbeBoundary)
      |> refute_issues()
    end

    test "no issues for a filename matched by the :allowed param" do
      """
      defmodule Tymeslot.Some.Exception do
        def call(module, config), do: module.perform_connection_test(config)
      end
      """
      |> to_source_file("lib/tymeslot/some/exception.ex")
      |> run_check(ConnectionProbeBoundary, allowed: ["lib/tymeslot/some/exception.ex"])
      |> refute_issues()
    end
  end

  describe "flagged calls" do
    test "perform_connection_test/1 called from a LiveComponent is flagged" do
      """
      defmodule TymeslotWeb.Dashboard.CalendarSettingsComponent do
        def handle_event("test", _params, socket) do
          {:noreply, assign(socket, :result, SomeProvider.perform_connection_test(config))}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard/calendar_settings_component.ex")
      |> run_check(ConnectionProbeBoundary)
      |> assert_issue(fn issue ->
        assert issue.trigger == "perform_connection_test"
      end)
    end

    test "call on a dynamically resolved provider module is flagged" do
      """
      defmodule Tymeslot.Integrations.Calendar.Diagnostics do
        def probe(provider_module, config), do: provider_module.perform_connection_test(config)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar/diagnostics.ex")
      |> run_check(ConnectionProbeBoundary)
      |> assert_issue(fn issue ->
        assert issue.trigger == "perform_connection_test"
      end)
    end
  end

  describe "no false positives for unrelated calls" do
    test "a same-named function with a different arity is not flagged" do
      """
      defmodule Tymeslot.Integrations.Calendar.Diagnostics do
        def probe(provider_module, config, opts), do: provider_module.perform_connection_test(config, opts)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar/diagnostics.ex")
      |> run_check(ConnectionProbeBoundary)
      |> refute_issues()
    end

    test "a different function on the same module is not flagged" do
      """
      defmodule Tymeslot.Integrations.Calendar.Diagnostics do
        def check(provider_module, config), do: provider_module.validate_config(config)
      end
      """
      |> to_source_file("lib/tymeslot/integrations/calendar/diagnostics.ex")
      |> run_check(ConnectionProbeBoundary)
      |> refute_issues()
    end
  end
end
