defmodule Tymeslot.CalendarGrid.EventEdit do
  @moduledoc """
  Editing an existing calendar-grid event: one change applied to the whole
  event, pushed to the provider, then written back to the cache.

  ## Why the whole event is sent

  Provider updates are full replaces, so a rename that sent only the title
  used to strip the event's attendees, reminders, repeat rule and colour. The
  payload is therefore always built by `Tymeslot.CalendarGrid.ProviderPayload`
  from the complete event after the change is applied, never from the change
  alone. `changes` speaks the cache's vocabulary; that module is the one place
  it is translated into the adapters'.

  ## Failure

  A failed provider write is queued for replay when the error is one a retry
  can recover (see `Calendar.Events.queueable_error?/1`) and the integration
  has an offline queue (the CalDAV family). A queued edit is also written to
  the cache, so the grid keeps showing what the organiser saved.
  """

  alias Tymeslot.CalendarGrid.ProviderPayload
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  require Logger

  @editable_fields ~w(summary description location start_at end_at all_day start_date end_date reminders recurrence_rule colour attendees)a

  @typedoc "An allowlisted map of cache fields to their new values."
  @type changes :: %{optional(atom()) => term()}

  @type failure :: %{reason: term(), retry: :queued | :not_queued}

  @doc """
  Applies `changes` to `event`, writes the whole updated event to the
  provider, and records the edit on the cached row.

  `changes` may only carry #{Enum.map_join(@editable_fields, ", ", &"`#{&1}`")};
  any other key raises `ArgumentError`. Timing follows the event's resulting `all_day`
  flag: an all-day event keeps its dates and drops its timestamps, a timed
  event the reverse.

  ## Options

    * `:recurrence_scope` - which occurrences of a recurring series the edit
      is meant for (`"this_only"`, `"following"`, `"all"`). Forwarded to the
      provider payload; no provider acts on it yet.

  Returns `{:ok, updated_event}`, or `{:error, %{reason: reason, retry:
  :queued | :not_queued}}` where `:queued` means the edit is saved locally
  and will be replayed on the next sync.
  """
  @spec update_event(pos_integer(), map(), changes(), keyword()) ::
          {:ok, map()} | {:error, failure()}
  def update_event(user_id, event, changes, opts \\ []) when is_map(changes) do
    ensure_editable!(changes)
    updated = apply_changes(event, changes)

    case ProviderPayload.from_event(updated) do
      {:ok, payload} ->
        payload = maybe_put_scope(payload, Keyword.get(opts, :recurrence_scope))
        write_to_provider(user_id, event, updated, payload)

      {:error, :invalid_timing} ->
        {:error, %{reason: :invalid_timing, retry: :not_queued}}
    end
  end

  defp write_to_provider(user_id, event, updated, payload) do
    case CalendarEvents.update_event(event.uid, payload, {event.calendar_integration_id, user_id}) do
      :ok ->
        record_local_edit(user_id, updated)
        {:ok, updated}

      {:error, reason} ->
        {:error, %{reason: reason, retry: queue_retry(user_id, updated, payload, reason)}}
    end
  end

  defp ensure_editable!(changes) do
    case Map.keys(changes) -- @editable_fields do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "cannot edit #{inspect(unknown)} on a calendar event; " <>
                "editable fields are #{inspect(@editable_fields)}"
    end
  end

  defp apply_changes(event, changes) do
    event
    |> Map.merge(changes)
    |> normalise_timing()
  end

  defp normalise_timing(%{all_day: true} = event), do: %{event | start_at: nil, end_at: nil}
  defp normalise_timing(event), do: %{event | start_date: nil, end_date: nil}

  defp maybe_put_scope(payload, nil), do: payload
  defp maybe_put_scope(payload, scope), do: Map.put(payload, :recurrence_scope, scope)

  defp queue_retry(user_id, event, payload, reason) do
    target = %{uid: event.uid, calendar_integration_id: event.calendar_integration_id}

    with true <- CalendarEvents.queueable_error?(reason),
         :ok <- CalendarEvents.queue_for_offline_retry(target, :update, payload) do
      # The queue marker is an upsert of the queue's own narrower columns, so
      # the edit is written again on top of it to keep attendees, reminders
      # and all-day dates on the row the grid reads.
      record_local_edit(user_id, event)
      :queued
    else
      _not_queued -> :not_queued
    end
  end

  # Deliberately no grid broadcast: the organiser's own grid already shows the
  # edit, and a reload would land in the middle of whatever they do next.
  defp record_local_edit(user_id, event) do
    case ProviderCalendarEventQueries.apply_local_edit(
           event.calendar_integration_id,
           event.uid,
           Map.take(event, @editable_fields)
         ) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("Calendar event edit reached the provider but not the cache",
          calendar_integration_id: event.calendar_integration_id,
          reason: inspect(reason)
        )
    end

    AvailabilityCache.invalidate_for_user(user_id)
  end
end
