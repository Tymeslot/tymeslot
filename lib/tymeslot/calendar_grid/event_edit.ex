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

  That keeps everything the cache models, which is not everything the event
  has: an event authored elsewhere carries properties Tymeslot never reads.
  For the CalDAV family the payload therefore travels with the cached
  `raw_ical` and its ETag, and the adapter patches that document property by
  property instead of rebuilding it, so an `ATTENDEE` block with its
  `PARTSTAT`, categories and `X-` properties survive an edit. Google and
  Outlook have no equivalent: their updates replace the event with the
  payload, and what the cache does not model is still lost there.

  ## Failure

  A failed provider write is queued for replay when the error is one a retry
  can recover (see `Calendar.Events.queueable_error?/1`) and the integration
  has an offline queue (the CalDAV family). A queued edit is also written to
  the cache, so the grid keeps showing what the organiser saved.
  """

  alias Tymeslot.CalendarGrid.AllDay
  alias Tymeslot.CalendarGrid.ProviderPayload
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

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
  event the reverse. A change that flips `all_day` also refits the `UNTIL` of
  a recurring event's rule to the value type its new `DTSTART` calls for.

  ## Options

    * `:recurrence_scope` - which occurrences of a recurring series the edit
      is meant for (`"this_only"`, `"following"`, `"all"`). Forwarded to the
      provider payload; no provider acts on it yet.
    * `:timezone` - the organiser's timezone. A timed event's `UNTIL` is an
      instant (RFC 5545 §3.3.10), so refitting one has to end the organiser's
      chosen day in their own zone; without it the day ends in UTC and the
      series gains or loses its last occurrence.

  Returns `{:ok, updated_event}`, or `{:error, %{reason: reason, retry:
  :queued | :not_queued}}` where `:queued` means the edit is saved locally
  and will be replayed on the next sync.
  """
  @spec update_event(pos_integer(), map(), changes(), keyword()) ::
          {:ok, map()} | {:error, failure()}
  def update_event(user_id, event, changes, opts \\ []) when is_map(changes) do
    ensure_editable!(changes)

    with {:ok, updated} <- apply_changes(event, changes, opts),
         {:ok, payload} <- ProviderPayload.from_event(updated) do
      payload =
        payload
        |> maybe_put_scope(Keyword.get(opts, :recurrence_scope))
        |> put_stored_document(event)

      write_to_provider(user_id, event, updated, payload)
    else
      {:error, reason} -> {:error, %{reason: reason, retry: :not_queued}}
    end
  end

  # The document the provider last gave us, for the adapters that can patch it
  # rather than rebuild the event from the payload. It is read from the cache
  # row rather than taken off `event`, which is whatever the grid last
  # assigned and may be an optimistic copy built from a form: a payload that
  # quietly arrived without a document would be rebuilt, which is the loss
  # this exists to prevent.
  defp put_stored_document(payload, event) do
    case ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid) do
      {:ok, %{raw_ical: raw_ical} = row} when is_binary(raw_ical) and raw_ical != "" ->
        Map.merge(payload, %{raw_ical: raw_ical, etag: row.etag})

      _never_synced ->
        payload
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

  defp apply_changes(event, changes, opts) do
    event
    |> Map.merge(changes)
    |> normalise_timing()
    |> retarget_rule(event.all_day, Keyword.get(opts, :timezone))
  end

  defp normalise_timing(%{all_day: true} = event), do: %{event | start_at: nil, end_at: nil}
  defp normalise_timing(event), do: %{event | start_date: nil, end_date: nil}

  # RFC 5545 §3.3.10: a rule's UNTIL carries the value type of the event's
  # DTSTART, so flipping all-day leaves a recurring event's existing rule in
  # the wrong form. Every other part of the rule is kept as it was.
  defp retarget_rule(%{all_day: all_day} = updated, all_day, _timezone), do: {:ok, updated}

  defp retarget_rule(updated, _was_all_day, timezone) do
    case RRule.retarget(updated.recurrence_rule,
           all_day: updated.all_day,
           start_date: AllDay.start_date(updated),
           timezone: timezone
         ) do
      {:ok, rule} -> {:ok, %{updated | recurrence_rule: rule}}
      {:error, :until_before_start} = error -> error
    end
  end

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
