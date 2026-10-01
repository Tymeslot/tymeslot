defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventRecurrence do
  @moduledoc "Recurrence scope confirmation handlers for the calendar grid."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.EventWrites
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrencePromptModal

  @spec handle_confirm_recurrence_scope(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_recurrence_scope(params, socket) do
    prompt = socket.assigns.recurrence_prompt

    case prompt && offered_scope(prompt, params) do
      nil ->
        {:noreply, socket}

      {:ok, scope} ->
        if scope in [:following, :all] and EventWrites.series_busy?(socket, prompt.event) do
          {:noreply, reverted} = handle_cancel_recurrence_prompt(%{}, socket)
          send(self(), {:flash, {:warning, series_saving_message()}})
          {:noreply, reverted}
        else
          socket = assign(socket, :recurrence_prompt, nil)
          {:noreply, replay_with_scope(prompt, scope, socket)}
        end

      # Only a tampered or stale button sends a scope the prompt never
      # offered. Nothing is written; the prompt closes as if cancelled, so
      # the optimistic change is taken back off the grid.
      :error ->
        {:noreply, reverted} = handle_cancel_recurrence_prompt(%{}, socket)
        send(self(), {:flash, {:error, unknown_scope_message()}})
        {:noreply, reverted}
    end
  end

  defp offered_scope(prompt, params) do
    with {:ok, scope} <- RecurrenceScope.parse(params["scope"]),
         true <- scope in RecurrencePromptModal.offered_scopes(prompt) do
      {:ok, scope}
    else
      _not_offered -> :error
    end
  end

  # A write to the whole series would race a change of another of its
  # events still saving, or its move (see `EventWrites`).
  defp series_saving_message do
    dgettext(
      "dashboard_calendar_events",
      "A change to this series is still saving. Please make this change once it has saved."
    )
  end

  defp unknown_scope_message do
    dgettext(
      "dashboard_calendar_events",
      "That choice is not available for this event, so nothing was changed."
    )
  end

  # The scope prompt gates two kinds of edit on a recurring series: a timing
  # change (a drag, a resize or an inline time) and a recurrence-rule change.
  #
  # Neither flashes success up front: a refusal or a failure answers with its
  # own flash once the write settles (see `CalendarEventHandlers`), and
  # flashing "Changes saved." before that would contradict it.
  defp replay_with_scope(%{kind: :recurrence_rule} = prompt, scope, socket) do
    EditWorkflow.update_event_async(
      socket,
      prompt.event,
      %{recurrence_rule: prompt.recurrence_rule},
      recurrence_scope: scope
    )
  end

  # Whether to tell the attendees is asked once the write in `scope` has
  # succeeded (see `EditWorkflow.apply_event_change/6`).
  defp replay_with_scope(prompt, scope, socket) do
    EditWorkflow.update_event_async(
      socket,
      prompt.event,
      %{start_at: prompt.new_start, end_at: prompt.new_end},
      recurrence_scope: scope,
      notify: Map.get(prompt, :notify)
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
