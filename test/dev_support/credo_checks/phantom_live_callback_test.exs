Code.require_file(
  "dev_support/credo_checks/phantom_live_callback.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.PhantomLiveCallbackTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.PhantomLiveCallback

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags handle_info/2 in a LiveComponent" do
      """
      defmodule TymeslotWeb.ScheduleSettingsComponent do
        use TymeslotWeb, :live_component

        def handle_info({:reload_schedule}, socket) do
          {:noreply, load_schedules(socket)}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard/schedule_settings_component.ex")
      |> run_check(PhantomLiveCallback)
      |> assert_issue(fn issue -> assert issue.trigger == "handle_info" end)
    end

    test "flags handle_info/2 in a module using Phoenix.LiveComponent directly" do
      """
      defmodule TymeslotWeb.PlainComponent do
        use Phoenix.LiveComponent

        def handle_info(:tick, socket), do: {:noreply, socket}
      end
      """
      |> to_source_file("lib/tymeslot_web/components/plain_component.ex")
      |> run_check(PhantomLiveCallback)
      |> assert_issue()
    end

    test "flags a guarded handle_info/2 clause in a LiveComponent" do
      """
      defmodule TymeslotWeb.PlainComponent do
        use TymeslotWeb, :live_component

        def handle_info(msg, socket) when is_atom(msg), do: {:noreply, socket}
      end
      """
      |> to_source_file("lib/tymeslot_web/components/plain_component.ex")
      |> run_check(PhantomLiveCallback)
      |> assert_issue()
    end

    test "flags handle_info/2 in the overlay repo's web namespace" do
      """
      defmodule TymeslotSaasWeb.PricingComponent do
        use TymeslotSaasWeb, :live_component

        def handle_info(:refresh, socket), do: {:noreply, socket}
      end
      """
      |> to_source_file("lib/tymeslot_saas_web/live/pricing_component.ex")
      |> run_check(PhantomLiveCallback)
      |> assert_issue()
    end

    test "flags each phantom clause separately" do
      """
      defmodule TymeslotWeb.PlainComponent do
        use TymeslotWeb, :live_component

        def handle_info(:tick, socket), do: {:noreply, socket}
        def handle_info(:tock, socket), do: {:noreply, socket}
      end
      """
      |> to_source_file("lib/tymeslot_web/components/plain_component.ex")
      |> run_check(PhantomLiveCallback)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "accepted cases" do
    test "accepts handle_info/2 in a LiveView" do
      """
      defmodule TymeslotWeb.DashboardLive do
        use TymeslotWeb, :live_view

        def handle_info({:reload_schedule}, socket) do
          {:noreply, load_schedules(socket)}
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard_live.ex")
      |> run_check(PhantomLiveCallback)
      |> refute_issues()
    end

    test "accepts terminate/2 in a GenServer" do
      """
      defmodule Tymeslot.Infrastructure.CacheStore do
        use GenServer

        def terminate(_reason, state), do: flush(state)
      end
      """
      |> to_source_file("lib/tymeslot/infrastructure/cache_store.ex")
      |> run_check(PhantomLiveCallback)
      |> refute_issues()
    end

    test "accepts update/2 and handle_event/3 in a LiveComponent" do
      """
      defmodule TymeslotWeb.PlainComponent do
        use TymeslotWeb, :live_component

        def update(assigns, socket), do: {:ok, assign(socket, assigns)}
        def handle_event("save", params, socket), do: {:noreply, save(socket, params)}
      end
      """
      |> to_source_file("lib/tymeslot_web/components/plain_component.ex")
      |> run_check(PhantomLiveCallback)
      |> refute_issues()
    end

    test "accepts a private handle_info/2 helper in a LiveComponent" do
      """
      defmodule TymeslotWeb.PlainComponent do
        use TymeslotWeb, :live_component

        defp handle_info(_msg, socket), do: socket
      end
      """
      |> to_source_file("lib/tymeslot_web/components/plain_component.ex")
      |> run_check(PhantomLiveCallback)
      |> refute_issues()
    end

    # terminate/2 is deliberately not a phantom callback: a graceful disconnect
    # stops the channel with {:stop, {:shutdown, reason}, state}, which runs
    # terminate/2 whether or not the process traps exits. Flagging it would tell
    # working cleanup code it is dead.
    test "accepts terminate/2 in a LiveView" do
      """
      defmodule TymeslotWeb.DashboardLive do
        use TymeslotWeb, :live_view

        def terminate(_reason, socket) do
          release_lock(socket)
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/dashboard_live.ex")
      |> run_check(PhantomLiveCallback)
      |> refute_issues()
    end

    test "accepts a handle_info/2 injected into a host LiveView through quote" do
      """
      defmodule TymeslotWeb.Themes.TimezoneHandlerComponent do
        defmacro __using__(_opts) do
          quote do
            def handle_info({:timezone_detected, tz}, socket) do
              {:noreply, assign(socket, :timezone, tz)}
            end
          end
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/themes/timezone_handler_component.ex")
      |> run_check(PhantomLiveCallback)
      |> refute_issues()
    end
  end
end
