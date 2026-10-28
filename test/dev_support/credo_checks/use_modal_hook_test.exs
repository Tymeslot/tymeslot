Code.require_file(
  "dev_support/credo_checks/use_modal_hook.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.UseModalHookTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.UseModalHook

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  @path "lib/tymeslot_web/live/dashboard/example_component.ex"

  describe "flagged cases" do
    test "flags an atom key passed to assign" do
      """
      defmodule TymeslotWeb.Dashboard.ExampleComponent do
        def handle_event("open", _params, socket) do
          {:noreply, assign(socket, :show_refund_modal, true)}
        end
      end
      """
      |> to_source_file(@path)
      |> run_check(UseModalHook)
      |> assert_issue(fn issue ->
        assert issue.trigger == "show_refund_modal"
        assert issue.line_no == 3
      end)
    end

    test "flags piped and module-qualified assigns, and assign_new" do
      """
      defmodule TymeslotWeb.Dashboard.ExampleComponent do
        def open(socket, payment) do
          socket
          |> Component.assign(:show_refund_modal, true)
          |> assign(:refund_modal_data, payment)
          |> assign_new(:disconnect_modal_open, fn -> false end)
        end
      end
      """
      |> to_source_file(@path)
      |> run_check(UseModalHook)
      |> assert_issues(fn issues ->
        assert issues |> Enum.map(& &1.trigger) |> Enum.sort() ==
                 ["disconnect_modal_open", "refund_modal_data", "show_refund_modal"]
      end)
    end

    test "flags keyword assigns once per key, with the call's line" do
      """
      defmodule TymeslotWeb.Dashboard.ExampleComponent do
        def close(socket) do
          assign(socket, show_delete_modal: false, delete_errors: %{})
        end
      end
      """
      |> to_source_file(@path)
      |> run_check(UseModalHook)
      |> assert_issue(fn issue ->
        assert issue.trigger == "show_delete_modal"
        assert issue.line_no == 3
      end)
    end

    test "flags a map literal passed to assign" do
      """
      defmodule TymeslotWeb.Dashboard.ExampleComponent do
        def close(socket), do: assign(socket, %{show_delete_modal: false})
      end
      """
      |> to_source_file(@path)
      |> run_check(UseModalHook)
      |> assert_issue(fn issue -> assert issue.trigger == "show_delete_modal" end)
    end

    test "flags an initial-state keyword list assigned elsewhere" do
      """
      defmodule TymeslotWeb.OnboardingLive.Initializer do
        defp initial_ui_state do
          [current_step: :welcome, show_skip_modal: false]
        end
      end
      """
      |> to_source_file("lib/tymeslot_web/live/onboarding_live/initializer.ex")
      |> run_check(UseModalHook)
      |> assert_issue(fn issue -> assert issue.trigger == "show_skip_modal" end)
    end
  end

  describe "accepted cases" do
    test "accepts ModalHook calls" do
      """
      defmodule TymeslotWeb.Dashboard.ExampleComponent do
        def mount(socket), do: {:ok, ModalHook.mount_modal(socket, refund: false)}

        def handle_event("open", _params, socket) do
          {:noreply, ModalHook.show_modal(socket, :refund, :payment)}
        end
      end
      """
      |> to_source_file(@path)
      |> run_check(UseModalHook)
      |> refute_issues()
    end

    test "accepts reads and function-head matches" do
      """
      defmodule TymeslotWeb.Dashboard.ExampleComponent do
        def handle_event("submit", _params, %{assigns: %{refund_modal_data: nil}} = socket),
          do: {:noreply, socket}

        def open?(socket), do: socket.assigns.show_refund_modal
      end
      """
      |> to_source_file(@path)
      |> run_check(UseModalHook)
      |> refute_issues()
    end

    test "accepts inline disclosure and view-switch state" do
      """
      defmodule TymeslotWeb.Dashboard.ExampleComponent do
        def toggle(socket) do
          socket
          |> assign(:show_password, true)
          |> assign(show_webhook_form: true, show_edit_overlay: false)
        end
      end
      """
      |> to_source_file(@path)
      |> run_check(UseModalHook)
      |> refute_issues()
    end

    test "ignores ModalHook itself and files outside lib/" do
      source = """
      defmodule TymeslotWeb.Hooks.ModalHook do
        def hide(socket), do: assign(socket, :show_refund_modal, false)
      end
      """

      source
      |> to_source_file("lib/tymeslot_web/hooks/modal_hook.ex")
      |> run_check(UseModalHook)
      |> refute_issues()

      source
      |> to_source_file("test/support/modal_helpers.ex")
      |> run_check(UseModalHook)
      |> refute_issues()
    end
  end
end
