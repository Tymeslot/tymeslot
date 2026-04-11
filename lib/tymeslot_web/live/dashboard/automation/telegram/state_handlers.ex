defmodule TymeslotWeb.Dashboard.Automation.Telegram.StateHandlers do
  @moduledoc """
  Handles state-transition events for Telegram integrations: toggling, testing,
  re-enabling, disconnecting, and reconnecting.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Telegram
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Live.Shared.Flash

  @spec handle_toggle(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.toggle_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Integration status updated")
            {:noreply, AutomationHelpers.maybe_load_telegram(socket)}

          {:error, :invalid_state} ->
            Flash.error("Cannot toggle in current state")
            {:noreply, socket}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to update status")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_test(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_test(%{"id" => id}, socket) do
    AutomationHelpers.do_rate_limited_test(
      socket,
      id,
      :telegram_testing,
      &AutomationHelpers.get_telegram_for_user(&1, id),
      &Telegram.test_integration/1,
      {"Test message sent! Check Telegram.", "Integration not found"}
    )
  end

  @spec handle_reenable(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reenable(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.reenable_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Integration re-enabled")
            {:noreply, AutomationHelpers.maybe_load_telegram(socket)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to re-enable")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_disconnect(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_disconnect(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.disconnect_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Telegram disconnected")
            {:noreply, AutomationHelpers.maybe_load_telegram(socket)}

          {:error, :own_bot_mode} ->
            Flash.error("Cannot disconnect in own-bot mode")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_reconnect(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reconnect(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        if socket.assigns.telegram_link_timer do
          Process.cancel_timer(socket.assigns.telegram_link_timer)
        end

        case Telegram.reconnect_integration(integration) do
          {:ok, updated, deep_link} ->
            timer_ref =
              Process.send_after(self(), {:telegram_link_expired, updated.id}, :timer.minutes(10))

            {:noreply,
             socket
             |> assign(:show_telegram_form, true)
             |> assign(:telegram_form_mode, :create)
             |> assign(:telegram_form_data, updated)
             |> assign(:telegram_form_timestamp, System.system_time())
             |> assign(:telegram_form_errors, %{})
             |> assign(:telegram_form_values, %{
               "name" => integration.name,
               "events" => integration.events
             })
             |> assign(:telegram_wizard_step, 1)
             |> assign(:telegram_link_expired, false)
             |> assign(:telegram_deep_link, deep_link)
             |> assign(:telegram_link_timer, timer_ref)
             |> assign(:telegram_form_is_stub, false)
             |> AutomationHelpers.maybe_load_telegram()}

          {:error, :own_bot_mode} ->
            Flash.error("Cannot reconnect in own-bot mode")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end
end
