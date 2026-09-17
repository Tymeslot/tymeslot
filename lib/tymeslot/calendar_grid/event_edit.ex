defmodule Tymeslot.CalendarGrid.EventEdit do
  @moduledoc """
  Editing an existing calendar-grid event: one change applied to the whole
  event, pushed to the provider, then written back to the cache.

  ## Why the whole event is sent

  Provider updates are full replaces. CalDAV rebuilds the VEVENT from the
  payload and Google's `events.update` is a `PUT`, so any field a payload
  leaves out is deleted from the organiser's calendar. A rename that sent
  only the title used to strip the event's attendees, reminders, repeat rule
  and colour. The payload is therefore always built from the complete event
  after the change is applied, never from the change alone.

  Complete means complete with respect to what the cache models. Properties
  Tymeslot never reads (categories, custom `X-` properties, alarm repeats)
  are still lost on a CalDAV or Google write.

  ## Vocabularies

  `changes` speaks the cache's vocabulary (`start_at`, `start_date`, ...);
  the provider payload speaks the adapters' (`start_time`, `end_time`). The
  two are translated here in one direction only, so a key cannot silently
  mean something to one side and nothing to the other.

  ## Failure

  A failed provider write is queued for replay when the error is one a retry
  can recover (see `Calendar.Events.queueable_error?/1`) and the integration
  has an offline queue (the CalDAV family). A queued edit is also written to
  the cache, so the grid keeps showing what the organiser saved.
  """

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  require Logger

  @editable_fields ~w(summary description location start_at end_at all_day start_date end_date reminders recurrence_rule colour attendees)a

  # Only provider statuses every adapter accepts on a write. A cached
  # `declined` describes the organiser's response, not the event, and Google
  # rejects it as an event status.
  @writable_statuses ~w(confirmed tentative cancelled)

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

    with :ok <- validate_timing(updated) do
      payload = provider_payload(updated, opts)
      context = {event.calendar_integration_id, user_id}

      case CalendarEvents.update_event(event.uid, payload, context) do
        :ok ->
          record_local_edit(user_id, updated)
          {:ok, updated}

        {:error, reason} ->
          {:error, %{reason: reason, retry: queue_retry(user_id, updated, payload, reason)}}
      end
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

  # A provider write without usable timing either crashes the CalDAV builder
  # or reaches the provider as an event with no start, so it never leaves.
  defp validate_timing(%{all_day: true, start_date: %Date{}, end_date: %Date{}}), do: :ok
  defp validate_timing(%{all_day: false, start_at: %DateTime{}, end_at: %DateTime{}}), do: :ok

  defp validate_timing(_event),
    do: {:error, %{reason: :invalid_timing, retry: :not_queued}}

  defp provider_payload(event, opts) do
    {start_time, end_time} = provider_timing(event)

    payload = %{
      summary: event.summary || "",
      description: event.description || "",
      location: event.location || "",
      start_time: start_time,
      end_time: end_time,
      all_day: event.all_day,
      attendees: event.attendees || [],
      reminders: event.reminders || [],
      recurrence_rule: event.recurrence_rule,
      recurrence_exceptions: event.recurrence_exceptions || [],
      colour: event.colour,
      transparency: event.transparency,
      visibility: event.visibility,
      status: writable_status(event.status),
      provider_event_id: event.provider_event_id,
      calendar_id: calendar_id(event.provider_calendar_id)
    }

    maybe_put_scope(payload, Keyword.get(opts, :recurrence_scope))
  end

  # Adapters read a `Date` as an all-day boundary and a `DateTime` as an
  # instant, so the type itself carries the distinction.
  defp provider_timing(%{all_day: true} = event), do: {event.start_date, event.end_date}
  defp provider_timing(event), do: {event.start_at, event.end_at}

  defp writable_status(status) when status in @writable_statuses, do: status
  defp writable_status(_status), do: nil

  # "primary" is the placeholder the Outlook sync writes when it does not know
  # which calendar an event is on, and Microsoft Graph has no calendar by that
  # id. Leaving it out lets each provider fall back to its own default, which
  # for Google is that same "primary" alias.
  defp calendar_id("primary"), do: nil
  defp calendar_id(calendar_id), do: calendar_id

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
