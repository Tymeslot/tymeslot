defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventRecurrence do
  @moduledoc "Recurrence scope confirmation handlers for the calendar grid."

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Updates
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_confirm_recurrence_scope(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_recurrence_scope(%{"scope" => scope}, socket) do
    case socket.assigns.recurrence_prompt do
      nil ->
        {:noreply, socket}

      prompt ->
        socket = assign(socket, :recurrence_prompt, nil)
        {:noreply, replay_with_scope(prompt, scope, socket)}
    end
  end

  # The scope prompt gates two kinds of edit on a recurring series: a timing
  # change (the default, original behaviour) and a recurrence-rule change.
  defp replay_with_scope(%{kind: :recurrence_rule} = prompt, scope, socket) do
    socket =
      Updates.update_recurrence_async(
        socket,
        prompt.event,
        prompt.recurrence_rule,
        recurrence_scope: scope
      )

    send(self(), {:flash, {:info, "Changes saved."}})
    socket
  end

  defp replay_with_scope(prompt, scope, socket) do
    Updates.update_event_async(
      socket,
      prompt.event,
      prompt.optimistic_event,
      prompt.new_start,
      prompt.new_end,
      recurrence_scope: scope
    )
  end

  @spec handle_cancel_recurrence_prompt(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_recurrence_prompt(_params, socket) do
    case socket.assigns.recurrence_prompt do
      nil ->
        {:noreply, socket}

      prompt ->
        reverted_events =
          Shared.replace_event(
            socket.assigns.events,
            prompt.original_event.id,
            prompt.original_event
          )

        socket =
          socket
          |> assign(:recurrence_prompt, nil)
          |> assign(:events, reverted_events)
          |> Helpers.precompute_derived()

        {:noreply, socket}
    end
  end
end
