defmodule TymeslotWeb.Dashboard.Automation.Slack.ModalHandlers do
  @moduledoc """
  Handles modal-related events for Slack integrations: delete confirmation
  and delivery-history viewer.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Slack
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  @spec handle_show_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_delete_modal(%{"id" => id}, socket) do
    {:noreply,
     socket
     |> ModalHook.show_modal(:slack_delete)
     |> assign(:slack_to_delete, AutomationHelpers.parse_id(id))}
  end

  @spec handle_hide_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_delete_modal(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:slack_delete)
     |> assign(:slack_to_delete, nil)}
  end

  @spec handle_delete(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete(_params, socket) do
    case socket.assigns.slack_to_delete do
      nil ->
        {:noreply, socket}

      id ->
        case AutomationHelpers.get_slack_for_user(socket, id) do
          {:ok, integration} ->
            case Slack.delete_integration(integration) do
              {:ok, _deleted} ->
                Flash.info("Slack integration deleted")

                {:noreply,
                 socket
                 |> ModalHook.hide_modal(:slack_delete)
                 |> assign(:slack_to_delete, nil)
                 |> AutomationHelpers.maybe_load_slack()}

              {:error, _reason} ->
                Flash.error("Failed to delete")
                {:noreply, socket}
            end

          {:error, _reason} ->
            Flash.error("Slack integration not found")
            {:noreply, socket}
        end
    end
  end

  @spec handle_show_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_deliveries(%{"id" => id}, socket) do
    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, integration} ->
        deliveries = Slack.list_deliveries(integration.id, limit: 50)
        stats = Slack.get_delivery_stats(integration.id, days: 7)

        {:noreply,
         socket
         |> ModalHook.show_modal(:slack_deliveries)
         |> assign(:selected_slack, integration)
         |> assign(:slack_deliveries, deliveries)
         |> assign(:slack_delivery_stats, stats)}

      {:error, _reason} ->
        Flash.error("Slack integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_hide_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_deliveries(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:slack_deliveries)
     |> assign(:selected_slack, nil)
     |> assign(:slack_deliveries, [])
     |> assign(:slack_delivery_stats, nil)}
  end
end
