defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventRecurrence do
  @moduledoc "Recurrence scope confirmation handlers for the calendar grid."

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_confirm_recurrence_scope(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_recurrence_scope(%{"scope" => scope}, socket) do
    case socket.assigns.recurrence_prompt do
      nil ->
        {:noreply, socket}

      prompt ->
        socket = assign(socket, :recurrence_prompt, nil)

        socket =
          EditWorkflow.update_event_async(
            socket,
            prompt.event,
            prompt.optimistic_event,
            prompt.new_start,
            prompt.new_end,
            recurrence_scope: scope
          )

        {:noreply, socket}
    end
  end

  @spec handle_cancel_recurrence_prompt(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_recurrence_prompt(_params, socket) do
    case socket.assigns.recurrence_prompt do
      nil ->
        {:noreply, socket}

      prompt ->
        reverted_events =
          Enum.map(socket.assigns.events, fn e ->
            if e.id == prompt.original_event.id, do: prompt.original_event, else: e
          end)

        socket =
          socket
          |> assign(:recurrence_prompt, nil)
          |> assign(:events, reverted_events)
          |> Helpers.precompute_derived()

        {:noreply, socket}
    end
  end
end
