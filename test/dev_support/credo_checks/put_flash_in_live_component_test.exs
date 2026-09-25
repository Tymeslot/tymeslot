Code.require_file(
  "dev_support/credo_checks/put_flash_in_live_component.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.PutFlashInLiveComponentTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.PutFlashInLiveComponent

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags a bare put_flash/3 in a LiveComponent" do
      """
      defmodule TymeslotWeb.Dashboard.PaymentsSettingsComponent do
        use TymeslotWeb, :live_component

        def handle_event("save", _params, socket) do
          {:noreply, put_flash(socket, :error, "Could not save")}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard/payments_settings_component.ex")
      |> run_check(PutFlashInLiveComponent)
      |> assert_issue(fn issue -> assert issue.trigger == "put_flash" end)
    end

    test "flags a piped put_flash/2 in a LiveComponent" do
      """
      defmodule TymeslotWeb.Dashboard.PaymentsSettingsComponent do
        use TymeslotWeb, :live_component

        def handle_event("save", _params, socket) do
          {:noreply, socket |> put_flash(:info, "Saved!")}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard/payments_settings_component.ex")
      |> run_check(PutFlashInLiveComponent)
      |> assert_issue(fn issue -> assert issue.trigger == "put_flash" end)
    end

    test "flags a module-qualified put_flash in a LiveComponent" do
      """
      defmodule TymeslotWeb.Dashboard.PaymentsSettingsComponent do
        use TymeslotWeb, :live_component

        def handle_event("save", _params, socket) do
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Payment not found.")}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard/payments_settings_component.ex")
      |> run_check(PutFlashInLiveComponent)
      |> assert_issue()
    end

    test "flags put_flash/3 in a module using Phoenix.LiveComponent directly" do
      """
      defmodule TymeslotWeb.PlainComponent do
        use Phoenix.LiveComponent

        def handle_event("save", _params, socket) do
          {:noreply, put_flash(socket, :error, "Could not save")}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/components/plain_component.ex")
      |> run_check(PutFlashInLiveComponent)
      |> assert_issue()
    end
  end

  describe "accepted cases" do
    test "accepts a bare put_flash/3 in a LiveView" do
      """
      defmodule TymeslotWeb.DashboardLive do
        use TymeslotWeb, :live_view

        def handle_event("save", _params, socket) do
          {:noreply, put_flash(socket, :error, "Could not save")}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard_live.ex")
      |> run_check(PutFlashInLiveComponent)
      |> refute_issues()
    end

    test "accepts a piped put_flash/2 in a LiveView" do
      """
      defmodule TymeslotWeb.DashboardLive do
        use TymeslotWeb, :live_view

        def handle_event("save", _params, socket) do
          {:noreply, socket |> put_flash(:info, "Saved!")}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard_live.ex")
      |> run_check(PutFlashInLiveComponent)
      |> refute_issues()
    end

    test "accepts Flash.put_flash/3 inside a LiveComponent" do
      """
      defmodule TymeslotWeb.Dashboard.PaymentsSettingsComponent do
        use TymeslotWeb, :live_component

        alias TymeslotWeb.Live.Shared.Flash

        def handle_event("save", _params, socket) do
          {:noreply, socket |> assign(:saving, false) |> Flash.put_flash(:error, "Could not save")}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard/payments_settings_component.ex")
      |> run_check(PutFlashInLiveComponent)
      |> refute_issues()
    end

    test "accepts Flash.error/1 in a module using Phoenix.LiveComponent directly" do
      """
      defmodule TymeslotWeb.PlainComponent do
        use Phoenix.LiveComponent

        alias TymeslotWeb.Live.Shared.Flash

        def handle_event("save", _params, socket) do
          Flash.error("Could not save")
          {:noreply, socket}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/components/plain_component.ex")
      |> run_check(PutFlashInLiveComponent)
      |> refute_issues()
    end
  end
end
