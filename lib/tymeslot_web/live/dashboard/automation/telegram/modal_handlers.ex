defmodule TymeslotWeb.Dashboard.Automation.Telegram.ModalHandlers do
  @moduledoc """
  Handles modal-related events for Telegram integrations: delete confirmation,
  delivery history, and PubSub-driven link/expiry callbacks.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Telegram
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  @spec handle_show_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_delete_modal(%{"id" => id}, socket) do
    {:noreply,
     socket
     |> ModalHook.show_modal(:telegram_delete)
     |> assign(:telegram_to_delete, AutomationHelpers.parse_id(id))}
  end

  @spec handle_hide_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_delete_modal(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:telegram_delete)
     |> assign(:telegram_to_delete, nil)}
  end

  @spec handle_delete(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete(_params, socket) do
    case socket.assigns.telegram_to_delete do
      nil ->
        {:noreply, socket}

      id ->
        case AutomationHelpers.get_telegram_for_user(socket, id) do
          {:ok, integration} ->
            case Telegram.delete_integration(integration) do
              {:ok, _deleted} ->
                Flash.info(dgettext("dashboard_automation_chat", "Integration deleted"))

                {:noreply,
                 socket
                 |> ModalHook.hide_modal(:telegram_delete)
                 |> assign(:telegram_to_delete, nil)
                 |> AutomationHelpers.maybe_load_telegram()}

              {:error, _reason} ->
                Flash.error(dgettext("dashboard_automation_chat", "Failed to delete"))
                {:noreply, socket}
            end

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_automation_chat", "Integration not found"))
            {:noreply, socket}
        end
    end
  end

  @spec handle_show_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_deliveries(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        deliveries = Telegram.list_deliveries(integration.id, limit: 50)
        stats = Telegram.get_delivery_stats(integration.id, days: 7)

        {:noreply,
         socket
         |> ModalHook.show_modal(:telegram_deliveries)
         |> assign(:selected_telegram, integration)
         |> assign(:telegram_deliveries, deliveries)
         |> assign(:telegram_delivery_stats, stats)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Integration not found"))
        {:noreply, socket}
    end
  end

  @spec handle_hide_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_deliveries(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:telegram_deliveries)
     |> assign(:selected_telegram, nil)
     |> assign(:telegram_deliveries, [])
     |> assign(:telegram_delivery_stats, nil)}
  end

  @doc """
  Handles the PubSub notification that a Telegram link was confirmed by the user.
  Advances the wizard to step 2 if the form is open for this integration.
  """
  @spec handle_linked(Phoenix.LiveView.Socket.t(), integer()) :: Phoenix.LiveView.Socket.t()
  def handle_linked(socket, integration_id) do
    if socket.assigns.telegram_link_timer do
      Process.cancel_timer(socket.assigns.telegram_link_timer)
    end

    socket = assign(socket, :telegram_link_timer, nil)

    if socket.assigns.show_telegram_form &&
         socket.assigns.telegram_form_data &&
         socket.assigns.telegram_form_data.id == integration_id do
      user_id = socket.assigns.current_user.id

      case Telegram.get_integration(integration_id, user_id) do
        {:ok, updated_integration} ->
          socket
          |> assign(:telegram_form_data, updated_integration)
          |> assign(:telegram_wizard_step, 2)
          |> AutomationHelpers.maybe_load_telegram()

        {:error, _reason} ->
          AutomationHelpers.maybe_load_telegram(socket)
      end
    else
      AutomationHelpers.maybe_load_telegram(socket)
    end
  end

  @doc """
  Handles the timer-based notification that a Telegram link has expired.
  Shows the expired state in the wizard if it is still on step 1 for this integration.
  """
  @spec handle_link_expired(Phoenix.LiveView.Socket.t(), integer()) :: Phoenix.LiveView.Socket.t()
  def handle_link_expired(socket, integration_id) do
    socket = assign(socket, :telegram_link_timer, nil)

    if socket.assigns.show_telegram_form &&
         socket.assigns.telegram_form_data &&
         socket.assigns.telegram_form_data.id == integration_id &&
         socket.assigns.telegram_wizard_step == 1 do
      assign(socket, :telegram_link_expired, true)
    else
      socket
    end
  end
end
