defmodule Tymeslot.CalendarGrid.EventDeletion do
  @moduledoc """
  Deleting a calendar-grid event: the provider delete, the Tymeslot meeting
  it may have been booked as, and the cached row the grid reads. Whenever the
  row changes, the organiser's cached availability is invalidated so the
  booking page stops treating the slot as taken.

  ## Linked meetings

  An event that is the calendar copy of a Tymeslot booking takes the booking
  with it: once the provider has deleted the event, the meeting is reconciled
  as externally deleted (see `Calendar.Events.delete_event_and_reconcile/4`),
  and the result says whether that cancellation went through. Nothing is
  reconciled when the delete fails.

  ## Recurring events

  A member of a series is deleted in one of two scopes, `:occurrence` (this
  event) or `:series` (all of them), and `deletion_scopes/1` says whether an
  event takes one. Both read the cached row rather than the event they were
  handed, because callers pass only the fields that address the event.

    * Google and Outlook give every occurrence an id of its own, so an
      occurrence is deleted by that id and the series by its master's.
    * The CalDAV family holds a whole series in one resource. An occurrence is
      deleted by rewriting the resource without it (see
      `Calendar.Events.delete_event/3`), after which every other cached row of
      the resource carries the new document. The series is deleted with the
      resource.
    * Exchange has no scoped delete, so its series are refused with
      `:recurring_event`.

  A series is never a Tymeslot booking, so deleting any part of one
  reconciles no meeting, and a room the series shares stays until the whole
  series goes.

  ## Failure

  A failed delete is queued for replay on the next sync when the error is one
  a retry can recover (see `Calendar.Events.queueable_error?/1`) and the
  integration has an offline queue (the CalDAV family). The queue marks the
  cached row `locally_deleted`, and the replay removes it once the server has
  deleted the event.

  A failed delete of a series member is never queued: the queue replays a
  delete as a DELETE of the whole resource, which would widen a CalDAV
  occurrence delete to its series.

  Only a delete the calendar refused is reported as a failure. Once the
  provider has removed the event there is nothing left to retry, so the
  local tidying that follows (the linked meeting, the cached row, the
  organiser's cached availability) can fail without changing the answer: the
  failure is logged, and the delete still returns `{:ok, deleted}`. The
  linked meeting is the one such step the organiser is told about, as
  `:cancel_failed`.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideoDiscard
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarResourceQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Recurrence.Series
  alias Tymeslot.Utils.MapKeys

  @type event :: %{
          required(:uid) => String.t(),
          required(:calendar_integration_id) => pos_integer(),
          optional(:provider_event_id) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "How much of a series a delete takes: the one occurrence, or all of it."
  @type scope :: :occurrence | :series

  @typedoc """
  What happened to the Tymeslot meeting the event was booked as: `:none` when
  it was not a booking, `:cancelled` when the meeting was cancelled with it,
  `:cancel_failed` when the event is gone but the meeting could not be
  cancelled.
  """
  @type linked_meeting :: :none | :cancelled | :cancel_failed

  @type deleted :: %{
          uid: String.t(),
          integration_id: pos_integer(),
          linked_meeting: linked_meeting()
        }

  @type failure :: %{reason: term(), retry: :queued | :not_queued}

  @doc """
  How `event` may be deleted from the grid: `{:ok, :single}` for an event
  outside any series, `{:ok, :series}` for a member of one, whose delete then
  takes a scope, and `{:error, :recurring_event}` for a series whose provider
  has no scoped delete (Exchange). Reads the cached row, as `delete_event/3`
  does.
  """
  @spec deletion_scopes(map()) :: {:ok, :single | :series} | {:error, :recurring_event}
  def deletion_scopes(event) do
    case event |> stored_event() |> series_family() do
      :single -> {:ok, :single}
      :unsupported -> {:error, :recurring_event}
      _family -> {:ok, :series}
    end
  end

  @doc """
  Deletes `event` from its calendar on behalf of `user_id`, cancels the
  meeting it was booked as, and removes its cached row.

  The event is addressed by its `:provider_event_id` when it has one, and by
  its iCal UID otherwise. For a member of a series, `scope` says whether the
  one occurrence or the whole series goes (see the moduledoc); it is ignored
  for any other event.

  Returns `{:ok, deleted}`, or `{:error, %{reason: reason, retry: :queued |
  :not_queued}}` where `:queued` means the delete will be replayed on the
  next sync. A series member is refused with `:recurring_event` when its
  provider has no scoped delete, and with `:unaddressable_occurrence` or
  `:unaddressable_series` when its cached row does not say which occurrence
  or series it is.
  """
  @spec delete_event(pos_integer(), event(), scope()) :: {:ok, deleted()} | {:error, failure()}
  def delete_event(user_id, event, scope \\ :occurrence)
      when scope in [:occurrence, :series] do
    stored = stored_event(event)

    case series_family(stored) do
      :single -> delete_single_event(user_id, event, stored)
      :unsupported -> {:error, %{reason: :recurring_event, retry: :not_queued}}
      family -> delete_series_member(user_id, event, stored, family, scope)
    end
  end

  defp stored_event(%{uid: uid, calendar_integration_id: integration_id} = event) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, record} -> record
      {:error, :not_found} -> event
    end
  end

  # Which scoped delete a series member's provider has: by the provider's own
  # occurrence and master ids (Google, Outlook), by rewriting the resource
  # (the CalDAV family), or none (Exchange, and anything else).
  defp series_family(stored) do
    provider = Map.get(stored, :provider)

    cond do
      not Series.member?(stored) -> :single
      ProviderConfig.caldav_based?(provider) -> :caldav
      ProviderConfig.oauth_provider?(provider) -> :provider_ids
      true -> :unsupported
    end
  end

  defp delete_single_event(
         user_id,
         %{uid: uid, calendar_integration_id: integration_id} = event,
         stored
       ) do
    provider_event_id = Map.get(event, :provider_event_id)

    # Both halves of the event's address: its own id, and the calendar it is
    # on. Without the calendar a Google or Outlook delete could only address
    # the integration's default booking calendar, so deleting an event on any
    # other one 404'd.
    opts =
      compact(
        provider_event_id: provider_event_id,
        calendar_id: Map.get(event, :provider_calendar_id)
      )

    case CalendarEvents.delete_event_and_reconcile(
           uid,
           provider_event_id,
           {integration_id, user_id},
           opts
         ) do
      {:ok, result} ->
        purge_local_traces(user_id, event, stored, :single)
        {:ok, %{uid: uid, integration_id: integration_id, linked_meeting: linked_meeting(result)}}

      {:error, reason} ->
        {:error, %{reason: reason, retry: queue_retry(event, reason)}}
    end
  end

  # Addressed from the cached row alone, which is what says which occurrence
  # and series the event is. No meeting is reconciled: a series is never a
  # Tymeslot booking, and a CalDAV occurrence shares its href with the whole
  # series, so a meeting matched by it would be cancelled for one occurrence.
  defp delete_series_member(
         user_id,
         %{uid: uid, calendar_integration_id: integration_id} = event,
         stored,
         family,
         scope
       ) do
    with {:ok, opts, removal} <- series_delete(family, scope, stored),
         {:ok, removal} <- provider_delete(uid, {integration_id, user_id}, opts, removal) do
      purge_local_traces(user_id, event, stored, removal)
      {:ok, %{uid: uid, integration_id: integration_id, linked_meeting: :none}}
    else
      {:error, reason} -> {:error, %{reason: reason, retry: :not_queued}}
    end
  end

  defp series_delete(:provider_ids, :occurrence, %{recurring_event_id: master_id} = stored)
       when is_binary(master_id) and master_id != "",
       do: {:ok, provider_ids_opts(stored, stored.provider_event_id), :occurrence}

  # A row naming no master is the master itself, whose id would take the whole
  # series.
  defp series_delete(:provider_ids, :occurrence, _stored),
    do: {:error, :unaddressable_occurrence}

  defp series_delete(:provider_ids, :series, stored) do
    case master_id(stored) do
      nil -> {:error, :unaddressable_series}
      master_id -> {:ok, provider_ids_opts(stored, master_id), {:series, master_id}}
    end
  end

  defp series_delete(:caldav, scope, %{provider_event_id: href} = stored)
       when is_binary(href) and href != "" do
    case scope do
      :series -> {:ok, provider_ids_opts(stored, href), {:resource, href}}
      :occurrence -> caldav_occurrence_delete(stored, href)
    end
  end

  defp series_delete(:caldav, :occurrence, _stored), do: {:error, :unaddressable_occurrence}
  defp series_delete(:caldav, :series, _stored), do: {:error, :unaddressable_series}

  defp caldav_occurrence_delete(stored, href) do
    with {:ok, key} <- occurrence_key(stored) do
      occurrence = %{
        href: href,
        key: key,
        timezone: Map.get(stored, :timezone),
        document: Map.get(stored, :raw_ical),
        etag: Map.get(stored, :etag)
      }

      {:ok, [provider_event_id: href, occurrence: occurrence], {:caldav_occurrence, href, nil}}
    end
  end

  defp provider_ids_opts(stored, provider_event_id),
    do:
      compact(
        provider_event_id: provider_event_id,
        calendar_id: Map.get(stored, :provider_calendar_id)
      )

  defp master_id(%{recurring_event_id: master_id}) when is_binary(master_id) and master_id != "",
    do: master_id

  defp master_id(%{recurrence_rule: rule, provider_event_id: own_id})
       when is_binary(rule) and rule != "" and is_binary(own_id) and own_id != "",
       do: own_id

  defp master_id(_stored), do: nil

  # A CalDAV occurrence is cached under its series' UID followed by the
  # occurrence's key, which is what the writer excludes. A uid that does not
  # carry that prefix names no occurrence the writer could find, and guessing
  # one could delete the wrong day.
  defp occurrence_key(%{uid: uid} = stored) do
    prefix = "#{MapKeys.get_binary(Map.get(stored, :provider_metadata), :uid)}_"

    case String.split_at(uid, String.length(prefix)) do
      {^prefix, key} when prefix != "_" and key != "" -> {:ok, key}
      _unaddressable -> {:error, :unaddressable_occurrence}
    end
  end

  defp provider_delete(uid, context, opts, removal) do
    case CalendarEvents.delete_event(uid, context, opts) do
      :ok -> {:ok, removal}
      {:ok, %{document: document}} -> {:ok, with_document(removal, document)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_document({:caldav_occurrence, href, _document}, document),
    do: {:caldav_occurrence, href, document}

  defp with_document(removal, _document), do: removal

  # `removal` is what the cached rows lose, now the provider has deleted:
  # `:single` or `:occurrence`, the event's own row;
  # `{:caldav_occurrence, href, document}`, the occurrence's row, with the
  # resource's new document on its siblings (all of them when `nil`, the
  # resource having been deleted); `{:series, master_id}` and
  # `{:resource, href}`, every row of the series.
  #
  # Every step runs after the event has already gone from the calendar, so none
  # of them may turn a delete that happened into one the organiser is told to
  # retry. A cached row that outlives its event is removed by the next sync
  # anyway, a video room left behind falls due to the nightly expiry scan, and
  # a stale availability entry expires on its own; a message telling the
  # organiser to delete an event that no longer exists does not recover. They
  # are rescued one by one so a failing room clean-up still leaves the cached
  # row deleted and the availability invalidated.
  defp purge_local_traces(
         user_id,
         %{uid: uid, calendar_integration_id: integration_id} = event,
         stored,
         removal
       ) do
    context = [user_id: user_id, calendar_integration_id: integration_id, uid: uid]

    after_delete("delete the event's video rooms", context, fn ->
      :ok = delete_recorded_rooms(event, stored, removal)
    end)

    after_delete("delete the cached event rows", context, fn ->
      purge_cached_rows(integration_id, uid, removal)
    end)

    # Read off the cached row, since the caller passes only the fields that
    # address the event: its link names the room no record holds (a Zoom
    # meeting's). Run once the cached rows are gone, since a room another
    # cached event still carries is left in place: the rest of a series keeps
    # its room while any of it remains, and loses it with the last row.
    after_delete("delete the event's unrecorded video room", context, fn ->
      :ok = EventVideoDiscard.event_deleted(user_id, stored)
    end)

    after_delete("invalidate cached availability", context, fn ->
      AvailabilityCache.invalidate_for_user(user_id)
    end)
  end

  # An occurrence leaves the rooms its series still uses. Its row cannot be
  # trusted to say so: a CalDAV occurrence edited on its own carries no repeat
  # rule, and shares its href with the room recorded for the series.
  defp delete_recorded_rooms(event, _stored, :single), do: EventVideoRooms.event_deleted(event)
  defp delete_recorded_rooms(_event, _stored, :occurrence), do: :ok

  defp delete_recorded_rooms(_event, stored, {:caldav_occurrence, _href, nil}),
    do: EventVideoRooms.series_deleted(stored)

  defp delete_recorded_rooms(_event, _stored, {:caldav_occurrence, _href, _document}), do: :ok
  defp delete_recorded_rooms(_event, stored, _series), do: EventVideoRooms.series_deleted(stored)

  defp purge_cached_rows(integration_id, uid, removal) when removal in [:single, :occurrence] do
    {:ok, _deleted_or_missing} = ProviderCalendarEventQueries.delete_by_uid(integration_id, uid)
  end

  # Nothing of the series was left, so the server deleted the resource.
  defp purge_cached_rows(integration_id, _uid, {:caldav_occurrence, href, nil}),
    do: purge_cached_rows(integration_id, nil, {:resource, href})

  defp purge_cached_rows(integration_id, uid, {:caldav_occurrence, href, document}) do
    {:ok, _deleted_or_missing} = ProviderCalendarEventQueries.delete_by_uid(integration_id, uid)
    ProviderCalendarResourceQueries.replace_document(integration_id, href, document)
  end

  # The master's own row, when cached, alongside its occurrences.
  defp purge_cached_rows(integration_id, _uid, {:series, master_id}) do
    ProviderCalendarEventQueries.delete_by_recurring_event_ids(integration_id, [master_id])
    ProviderCalendarEventQueries.delete_by_provider_event_ids(integration_id, [master_id])
  end

  defp purge_cached_rows(integration_id, _uid, {:resource, href}),
    do: ProviderCalendarEventQueries.delete_by_provider_event_ids(integration_id, [href])

  defp after_delete(step, context, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error(
        "Calendar grid delete: local cleanup failed after the event was deleted",
        [step: step, error: Exception.format(:error, error, __STACKTRACE__)] ++ context
      )

      :ok
  end

  defp compact(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

  defp linked_meeting(%{meeting_attendee_email: _email, reconcile_result: :ok}), do: :cancelled

  defp linked_meeting(%{meeting_attendee_email: _email, reconcile_result: {:error, _reason}}),
    do: :cancel_failed

  defp linked_meeting(_result), do: :none

  # A queued delete has not reached the calendar yet: the event is still on
  # the server and the grid puts it back. The organiser's availability is
  # therefore left alone until the delete actually lands, so a slot the event
  # still occupies is not offered to bookers in the meantime.
  defp queue_retry(%{uid: uid, calendar_integration_id: integration_id}, reason) do
    target = %{uid: uid, calendar_integration_id: integration_id}

    with true <- CalendarEvents.queueable_error?(reason),
         :ok <- CalendarEvents.queue_for_offline_retry(target, :delete, %{}) do
      :queued
    else
      _not_queued -> :not_queued
    end
  end
end
