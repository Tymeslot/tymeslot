defmodule Tymeslot.CalendarGrid.EventMove do
  @moduledoc """
  Moving a calendar-grid event to another calendar.

  No provider can move an event between accounts, so a move is a create on
  the destination followed by a delete on the source.

  ## Create first

  The destination is written first, and the source is only deleted once the
  destination has accepted the event. A failed create therefore leaves the
  organiser exactly where they started. The opposite order lost the event
  whenever the create failed, which it always did for all-day events.

  A failed delete after a successful create cannot lose anything either: the
  event exists on the destination, and the original is either queued for
  deletion on the next sync (the CalDAV family, whose offline queue replays
  deletes) or left in place for the organiser to remove. Anything that raises
  once the create has succeeded is reported as that, never as a move that did
  not happen, since the event is on the destination by then.

  ## Which uid the moved row gets

  The one the destination's sync will key the event by, so the next sync
  updates the row rather than adding a second one beside it. For the CalDAV
  family that is the uid the create was written under; Google and Outlook
  report an iCalendar UID of their own on the create, which is what their
  syncs key by (`CreatedEvent.cache_uid/1`).

  ## What travels with the event

  The destination receives the whole event through
  `Tymeslot.CalendarGrid.ProviderPayload`: timing (dates for an all-day
  event), description, location, attendees, reminders and colour. A video
  link travels in the description it was written into, and the cached link
  and video integration are carried onto the destination's row.

  ## Recurring events

  A series or one of its occurrences is refused. The create path writes a
  single event, so a move would turn a series into a one-off and, on CalDAV
  where an occurrence is addressed through its series' resource, delete
  every occurrence rather than the one the organiser picked.

  An occurrence edited on its own needs its own check on the iCalendar
  providers. It is a VEVENT with a `RECURRENCE-ID` and no `RRULE`, so its row
  carries no repeat rule and names no series, yet it lives in the series'
  resource like every other occurrence. Only the recurrence id the sync keeps
  in `provider_metadata` marks it.

  Exchange sets none of those fields. Its only series marker is the EWS item
  type the sync keeps in `provider_metadata`, and it matters most for the
  series itself: a server that does not expand series (grommunio) puts the
  `RecurringMaster` on the grid, and deleting it by its item id removes every
  occurrence.
  """

  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.ProviderPayload
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Recurrence.Series

  require Logger

  # Cache columns describing the event itself, copied to the destination row.
  # Everything the source provider owns (etag, raw_ical, provider_event_id,
  # provider_metadata) belongs to the original resource and is left behind.
  @carried_fields ~w(summary description location visibility colour all_day start_date end_date
                     start_at end_at timezone transparency status organiser attendees reminders
                     attachments links video_link video_integration_id)a

  @type destination :: %{
          required(:integration) => map(),
          optional(:calendar_id) => String.t() | nil
        }

  @type moved :: %{
          required(:uid) => String.t(),
          required(:integration_id) => pos_integer(),
          optional(:source) => :queued_delete | :left_behind | :unknown
        }

  @doc """
  Whether `event` may be moved to another calendar.

  Returns `{:error, :recurring_event}` for a recurring series (it carries a
  repeat rule), for an occurrence of one (it names its series), for an
  occurrence edited on its own (it carries a recurrence id) and for any
  Exchange item that is not a `Single` one.
  """
  @spec ensure_movable(map()) :: :ok | {:error, :recurring_event}
  def ensure_movable(event) do
    if Series.member?(event), do: {:error, :recurring_event}, else: :ok
  end

  @doc """
  Moves `event` to `destination`'s integration, on the calendar named by
  `:calendar_id` or that integration's default when it is `nil`.

  Returns `{:ok, %{uid: uid, integration_id: id}}` once the event is on the
  destination and gone from the source. When the source delete failed, the
  result also carries `:source`: `:queued_delete` when the delete will be
  replayed on the next sync, `:left_behind` when the original is still on its
  calendar, and `:unknown` when something failed after the destination accepted
  the event, which is then there while the original may or may not be. Returns
  `{:error, reason}`, with nothing written anywhere, when the event cannot be
  moved or the destination refused it, including
  `{:error, :no_destination_calendar}` when the destination integration has no
  calendar to write to.
  """
  @spec move_event(pos_integer(), map(), destination()) ::
          {:ok, moved()}
          | {:error, :recurring_event | :no_destination_calendar | :invalid_timing | term()}
  def move_event(user_id, event, %{integration: integration} = destination) do
    with :ok <- ensure_movable(event),
         moved = moved_event(event, integration, Map.get(destination, :calendar_id)),
         :ok <- ensure_destination(moved),
         {:ok, payload} <- ProviderPayload.from_event(moved),
         {:ok, created} <- create_on_destination(user_id, moved, payload) do
      settle_move(user_id, event, moved, created)
    end
  end

  # Everything after the create. The event now exists on the destination, so
  # nothing from here on may report that it was not moved: a raise past this
  # point is reported as `source: :unknown`, since the original may or may not
  # have been deleted by then. A raise before the create returned escapes to
  # the caller as before, where "nothing moved" is the truth.
  defp settle_move(user_id, event, moved, %CreatedEvent{} = created) do
    integration_id = moved.calendar_integration_id
    cached_uid = CreatedEvent.cache_uid(created) || moved.uid

    try do
      finish_move(user_id, event, moved, created, cached_uid)
    catch
      kind, reason ->
        Logger.error("Calendar event move failed after the destination accepted it",
          calendar_integration_id: integration_id,
          kind: kind,
          reason: failure_label(kind, reason)
        )

        AvailabilityCache.invalidate_for_user(user_id)
        {:ok, %{uid: cached_uid, integration_id: integration_id, source: :unknown}}
    end
  end

  defp finish_move(user_id, event, moved, created, cached_uid) do
    # The event keeps its description, and with it the join link, so its
    # video rooms follow it to the new identity. `moved.uid` is the uid the
    # create was written with; the provider's answer is how it addresses the
    # event, which is the same except where the provider assigns its own. The
    # calendar is the one the destination actually wrote to, the same one the
    # cached row below is filed under.
    :ok =
      EventVideoRooms.moved(
        event,
        moved.calendar_integration_id,
        moved.uid,
        CreatedEvent.local_uid(created) || moved.uid,
        created.calendar_id || moved.provider_calendar_id
      )

    # Cached under the key the destination's sync will look the event up by,
    # so the next sync updates this row instead of adding a second one.
    cache_destination(%{moved | uid: cached_uid}, created)
    result = %{uid: cached_uid, integration_id: moved.calendar_integration_id}

    result =
      case remove_source(user_id, event) do
        :removed -> result
        left -> Map.put(result, :source, left)
      end

    AvailabilityCache.invalidate_for_user(user_id)
    {:ok, result}
  end

  # The exception's type, never its message: a failed match carries the row
  # it failed on, event details included.
  defp failure_label(:error, %{__exception__: true, __struct__: module}), do: inspect(module)
  defp failure_label(kind, _reason), do: Atom.to_string(kind)

  # The event as it will exist on the destination. The uid is generated here
  # so that the create and the cache row address the same event.
  defp moved_event(event, integration, calendar_id) do
    %{
      event
      | uid: ICalBuilder.generate_uid(),
        calendar_integration_id: integration.id,
        provider: integration.provider,
        provider_calendar_id: destination_calendar_id(integration, calendar_id),
        provider_event_id: nil
    }
  end

  # The chosen calendar first, for every provider: CalDAV writes now honour
  # `event_data[:calendar_id]` when it names a writable collection, so filing
  # the row under the booking collection regardless is no longer the truth.
  # `booking_calendar_path/1` resolves nothing when the stored booking calendar
  # id matches no discovered collection, which is the state a rediscovery
  # leaves behind; the create falls back to the first discovered collection, so
  # the row follows it rather than being filed under a null the column rejects.
  # The "primary" placeholder is only meaningful to the OAuth providers, where
  # it names the account's own calendar.
  defp destination_calendar_id(integration, calendar_id) do
    if integration.provider in Calendar.caldav_based_provider_strings() do
      calendar_id || Calendar.booking_calendar_path(integration) ||
        List.first(integration.calendar_paths)
    else
      calendar_id || integration.default_booking_calendar_id || "primary"
    end
  end

  # An integration whose discovery left no collection at all has nowhere to
  # write to. Refusing before the create keeps a destination the cache row
  # cannot name from accepting the event anyway, which would leave a copy on
  # the destination while the organiser is told nothing moved.
  defp ensure_destination(%{provider_calendar_id: nil}), do: {:error, :no_destination_calendar}
  defp ensure_destination(_moved), do: :ok

  defp create_on_destination(user_id, moved, payload) do
    payload =
      payload
      |> Map.delete(:provider_event_id)
      |> Map.put(:uid, moved.uid)

    CalendarEvents.create_event(payload, {moved.calendar_integration_id, user_id})
  end

  # The destination's answer carries the event's identity there, which is the
  # one thing the moved row cannot inherit from the source: the href and ETag
  # it held belonged to the resource that is about to be deleted.
  defp cache_destination(moved, %CreatedEvent{} = created) do
    row =
      moved
      |> Map.take(@carried_fields)
      |> Map.merge(%{
        uid: moved.uid,
        calendar_integration_id: moved.calendar_integration_id,
        provider: moved.provider,
        # What the destination actually wrote, before what was asked for: a
        # CalDAV create falls back to the booking collection when the chosen
        # calendar is not one the integration lists as writable, and filing
        # the row under the request would put the moved event on a calendar it
        # is not on.
        provider_calendar_id: created.calendar_id || moved.provider_calendar_id,
        provider_event_id: created.provider_event_id,
        etag: created.etag,
        synced_at: DateTime.utc_now(:microsecond)
      })

    {:ok, _count} = ProviderCalendarEventQueries.upsert_batch([row])
    :ok
  end

  defp remove_source(user_id, event) do
    # The source's own calendar, not the integration's default: a move away
    # from a secondary Google or Outlook calendar used to address the default
    # one and 404, leaving the original behind beside the copy.
    opts =
      Enum.reject(
        [provider_event_id: event.provider_event_id, calendar_id: event.provider_calendar_id],
        fn {_key, value} -> is_nil(value) end
      )

    context = {event.calendar_integration_id, user_id}

    case CalendarEvents.delete_event(event.uid, context, opts) do
      :ok ->
        {:ok, _deleted} =
          ProviderCalendarEventQueries.delete_by_uid(event.calendar_integration_id, event.uid)

        :removed

      {:error, reason} ->
        queue_source_delete(event, reason)
    end
  end

  # A `:not_found` is not taken as "already gone": the source may simply have
  # been looked for on the wrong calendar, and reporting it removed would hide
  # a duplicate the organiser has to clean up.
  defp queue_source_delete(event, reason) do
    target = %{uid: event.uid, calendar_integration_id: event.calendar_integration_id}

    with true <- CalendarEvents.queueable_error?(reason),
         :ok <- CalendarEvents.queue_for_offline_retry(target, :delete, %{}) do
      :queued_delete
    else
      _not_queued ->
        Logger.warning("Moved calendar event was copied but its original could not be deleted",
          calendar_integration_id: event.calendar_integration_id,
          reason: inspect(reason)
        )

        :left_behind
    end
  end
end
