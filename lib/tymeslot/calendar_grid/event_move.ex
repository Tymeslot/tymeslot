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
  deletes) or left in place for the organiser to remove.

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
  """

  alias Tymeslot.CalendarGrid.ProviderPayload
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Utils.MapKeys

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
          optional(:source) => :queued_delete | :left_behind
        }

  @doc """
  Whether `event` may be moved to another calendar.

  Returns `{:error, :recurring_event}` for a recurring series (it carries a
  repeat rule) and for an occurrence of one (it names its series).
  """
  @spec ensure_movable(map()) :: :ok | {:error, :recurring_event}
  def ensure_movable(event) do
    if present?(Map.get(event, :recurrence_rule)) or present?(Map.get(event, :recurring_event_id)),
      do: {:error, :recurring_event},
      else: :ok
  end

  @doc """
  Moves `event` to `destination`'s integration, on the calendar named by
  `:calendar_id` or that integration's default when it is `nil`.

  Returns `{:ok, %{uid: uid, integration_id: id}}` once the event is on the
  destination and gone from the source. When the source delete failed, the
  result also carries `:source`: `:queued_delete` when the delete will be
  replayed on the next sync, `:left_behind` when the original is still on its
  calendar. Returns `{:error, reason}`, with nothing written anywhere, when
  the event cannot be moved or the destination refused it.
  """
  @spec move_event(pos_integer(), map(), destination()) ::
          {:ok, moved()} | {:error, :recurring_event | :invalid_timing | term()}
  def move_event(user_id, event, %{integration: integration} = destination) do
    with :ok <- ensure_movable(event),
         moved = moved_event(event, integration, Map.get(destination, :calendar_id)),
         {:ok, payload} <- ProviderPayload.from_event(moved),
         {:ok, created} <- create_on_destination(user_id, moved, payload) do
      moved = %{moved | uid: created_uid(created, moved.uid)}
      cache_destination(moved)
      result = %{uid: moved.uid, integration_id: integration.id}

      result =
        case remove_source(user_id, event) do
          :removed -> result
          left -> Map.put(result, :source, left)
        end

      AvailabilityCache.invalidate_for_user(user_id)
      {:ok, result}
    end
  end

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

  # The CalDAV family writes every new event to the integration's booking
  # collection whatever calendar was asked for, so the row is filed under the
  # path actually written to. The "primary" placeholder is only meaningful
  # to the OAuth providers, where it names the account's own calendar.
  defp destination_calendar_id(integration, calendar_id) do
    if integration.provider in Calendar.caldav_based_provider_strings() do
      Calendar.booking_calendar_path(integration)
    else
      calendar_id || integration.default_booking_calendar_id || "primary"
    end
  end

  defp create_on_destination(user_id, moved, payload) do
    payload =
      payload
      |> Map.delete(:provider_event_id)
      |> Map.put(:uid, moved.uid)

    CalendarEvents.create_event(payload, {moved.calendar_integration_id, user_id})
  end

  # CalDAV answers with the uid it was given; the OAuth providers with the
  # event they created, whose id is the one they will know it by.
  defp created_uid(created, _uid) when is_binary(created), do: created

  defp created_uid(created, uid) when is_map(created),
    do: MapKeys.get_binary(created, :uid) || uid

  defp created_uid(_created, uid), do: uid

  defp cache_destination(moved) do
    row =
      moved
      |> Map.take(@carried_fields)
      |> Map.merge(%{
        uid: moved.uid,
        calendar_integration_id: moved.calendar_integration_id,
        provider: moved.provider,
        provider_calendar_id: moved.provider_calendar_id,
        synced_at: DateTime.utc_now(:microsecond)
      })

    {:ok, _count} = ProviderCalendarEventQueries.upsert_batch([row])
    :ok
  end

  defp remove_source(user_id, event) do
    opts = if event.provider_event_id, do: [provider_event_id: event.provider_event_id], else: []
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

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
