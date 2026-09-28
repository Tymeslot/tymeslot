defmodule Tymeslot.CalendarGrid.SeriesTransfer do
  @moduledoc """
  Moving a whole recurring series to another calendar from the grid.

  `Tymeslot.CalendarGrid.EventMove.move_event/3` routes a move here when the
  cached row belongs to a series whose provider has series-wide writes
  (`EventMove.ensure_movable/1` answers `{:ok, :series}`). Moving one
  occurrence would take it out of its series, so the move is always of the
  whole series, from whichever of its rows the organiser picked.

  ## Which moves are possible

  The series is written to the destination as the provider holds it, which
  only a provider of the same family can take: Google to Google, Outlook to
  Outlook, and within the CalDAV family (any integration of any CalDAV-based
  provider, on the same server or another). Anything else is refused with
  `:cross_provider_series` before anything is written: a series carried
  across families would have to be rebuilt from the cache, losing whatever
  the cache does not hold of it. Exchange has no series-wide write, and its
  series are refused with `:recurring_event`, as `ensure_movable/1` refuses
  them.

  The series is addressed as its provider addresses it
  (`Tymeslot.CalendarGrid.Occurrence.series_address/1`): a Google or Outlook
  series by its master's id, a CalDAV series by its resource's href. A row
  that names neither is refused with `:unaddressable_series`, and a
  destination with no calendar to write to with `:no_destination_calendar`.

  ## The writers

  Each family has a writer of its own, `write/2`, which creates the series on
  the destination first and deletes it at the source only once the
  destination has accepted it, so a failed create leaves the organiser where
  they started. A writer is handed the transfer (`t:transfer/0`) and answers
  `{:error, reason}` when nothing was written, or `{:ok, written}`
  (`t:written/0`) once the destination holds the series:

    * `:uid`, the new series' iCalendar UID, which its occurrences are cached
      under once the destination is synced.
    * `:id`, how the destination's provider addresses the new series: its
      master's id on Google and Outlook, its resource's href on CalDAV.
    * `:calendar_id`, the calendar the series was written to.
    * `:source`, `:removed` once the series is gone from the source, or
      `:left_behind` when the delete failed and the original is still there.

  A failed delete is never queued for offline replay: the CalDAV queue
  replays a series member's delete as a delete of the whole resource, and
  Google and Outlook have no queue. The copy on the destination is kept,
  since deleting it again would lose the move the organiser asked for, and
  the result says the original was left behind.

  The CalDAV family's writer copies the series' resource, the cached
  document with its ETag or else the server's copy, under a fresh UID into
  the destination collection, which must be one the destination integration
  writes to, and then deletes the original under that ETag
  (`CalendarEvents.move_caldav_series/4`). Each request goes out on its own
  integration's client, so the two ends may be different servers.

  The Google writer moves the series' master from the calendar its rows are
  cached under (`"primary"` when they name none). Within one integration it
  uses Google's own move, which keeps the master's id and `iCalUID`, every
  instance edited on its own and the Meet; across integrations it copies
  the master, its whole recurrence included, into the destination and then
  deletes it at the source, each on its own integration's credentials
  (`CalendarEvents.move_google_series/3`). A move to the calendar the series
  is already on is refused with `:same_calendar`.

  The Outlook writer always copies, since Graph has no move for events: it
  reads the master, creates it with its own recurrence and timing in the
  destination calendar (the account's default one, as Graph names it, when
  the grid knows it only as `"primary"`), and then deletes the master at
  the source, each on its own integration's credentials
  (`CalendarEvents.move_outlook_series/3`). The copy has no Teams meeting of
  its own, and occurrences edited or cancelled on their own are not carried.
  A move to the calendar the series is on is refused with `:same_calendar`;
  Outlook rows are mostly cached as on `"primary"`, so within one
  integration the calendar Graph says holds the master is what settles it.

  A writer can be handed to `move/4` as its `:writer` option, which is how
  the steps after the write are exercised on their own.

  ## After the write

  Every writer shares the same tail, run once the destination holds the
  series:

    * The series' recorded video rooms follow it to the destination
      (`EventVideoRooms.series_moved/5`), since its occurrences carry the
      join link in the description the move copied.
    * The series' cached rows on the source are deleted
      (`EventDeletion.delete_series_rows/2`); the cache holds nothing of the
      new series yet. What only Tymeslot knows of the series goes with it
      (`SeriesCarry`): its video, for the destination's sync to find, and
      the organiser's colour overrides, moved to the uids its occurrences
      will be cached under there.
    * The organiser's cached availability is invalidated.
    * A sync of the destination integration is requested, which caches the
      series where it now lives, and one of the source integration when it
      is another, which confirms it gone or brings back an original left
      behind (`SeriesEdit.request_sync/2`).

  ## Before the move

  `notes/2` answers, before anything is written, whether a series can move
  to a destination integration at all and what the organiser should be told
  the move will not carry, so the grid can ask them to confirm it knowing
  that.

  None of these steps can undo the move, so none of them may report it as
  one that did not happen: each is rescued and logged on its own, and the
  move is still reported.
  """

  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.EventMove
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.SeriesCarry
  alias Tymeslot.CalendarGrid.SeriesEdit
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  require Logger

  @typedoc "The families a series can move within."
  @type family :: :google | :outlook | :caldav

  @typedoc """
  What a writer is handed: the acting user, the series' cached row on the
  source and its address there, and the destination integration and
  calendar.
  """
  @type transfer :: %{
          user_id: pos_integer(),
          stored: map(),
          address: Occurrence.series_address(),
          integration: map(),
          calendar_id: String.t()
        }

  @typedoc "What a writer answers once the destination holds the series."
  @type written :: %{
          uid: String.t(),
          id: String.t(),
          calendar_id: String.t(),
          source: :removed | :left_behind
        }

  @typedoc """
  Something a move to a given destination does not carry, which the
  organiser is told before confirming it:

    * `:changed_occurrences_reset` - occurrences edited on their own come
      back on the destination as the series' rule makes them (Google, when
      the series is copied to another integration).
    * `:changed_or_cancelled_occurrences_reset` - occurrences edited or
      cancelled on their own come back as the rule makes them (Outlook,
      which always copies).
    * `:teams_meeting_not_carried` - a Teams meeting on the series is not
      carried to the copy (Outlook). The cache does not record whether the
      series has one, so this is said of every Outlook move.
    * `:guests_reinvited` - the series' guests are sent a cancellation of
      the original and an invitation to the copy (Outlook, when the cached
      row has attendees).
  """
  @type note ::
          :changed_occurrences_reset
          | :changed_or_cancelled_occurrences_reset
          | :teams_meeting_not_carried
          | :guests_reinvited

  @doc """
  Whether the series `stored`, the cached row of one of its members, can
  move to `integration`, and if so what the move will not carry
  (`t:note/0`), in the order the organiser should read them.

  Refuses as `move/4` refuses before anything is written:
  `:recurring_event` for a provider with no series-wide write,
  `:cross_provider_series` for a destination of another family, and
  `:unaddressable_series` for a row that names no series. A move to the
  calendar the series is already on is only refused by `move/4`, which is
  when the destination calendar is settled.

  A move within one Google integration is Google's own, which carries
  everything, and a CalDAV move copies the series' whole resource, so
  neither has notes.
  """
  @spec notes(map(), map()) ::
          {:ok, [note()]}
          | {:error, :recurring_event | :cross_provider_series | :unaddressable_series}
  def notes(stored, integration) do
    with {:ok, family} <- same_family(stored, integration),
         {:ok, _address} <- Occurrence.series_address(stored) do
      {:ok, family_notes(family, stored, integration)}
    end
  end

  defp family_notes(:google, %{calendar_integration_id: id}, %{id: id}), do: []
  defp family_notes(:google, _stored, _integration), do: [:changed_occurrences_reset]

  defp family_notes(:outlook, stored, _integration) do
    guests = if Map.get(stored, :attendees) in [nil, []], do: [], else: [:guests_reinvited]
    [:changed_or_cancelled_occurrences_reset, :teams_meeting_not_carried | guests]
  end

  defp family_notes(:caldav, _stored, _integration), do: []

  @doc """
  Moves the series `stored`, the cached row of one of its members, to
  `destination`'s integration, on the calendar named by `:calendar_id` or
  that integration's default when it is `nil`.

  Returns what `EventMove.move_event/3` returns for a one-off event:
  `{:ok, %{uid: uid, integration_id: id}}`, with `source: :left_behind` when
  the original could not be deleted, or `{:error, reason}` with nothing
  written (see the moduledoc for the refusals).

  `opts` takes `:writer`, a function of the family and the transfer that
  answers as a writer does (see *The writers*), in place of the family's
  own.
  """
  @spec move(pos_integer(), map(), EventMove.destination(), keyword()) ::
          {:ok, EventMove.moved()}
          | {:error,
             :recurring_event
             | :cross_provider_series
             | :unaddressable_series
             | :no_destination_calendar
             | :same_calendar
             | term()}
  def move(user_id, stored, %{integration: integration} = destination, opts \\ []) do
    writer = Keyword.get(opts, :writer, &write/2)

    with {:ok, family} <- same_family(stored, integration),
         {:ok, address} <- Occurrence.series_address(stored),
         {:ok, calendar_id} <- calendar(integration, Map.get(destination, :calendar_id)),
         {:ok, written} <-
           writer.(family, %{
             user_id: user_id,
             stored: stored,
             address: address,
             integration: integration,
             calendar_id: calendar_id
           }) do
      settle(user_id, stored, integration, written)
    end
  end

  defp same_family(stored, integration) do
    case {family(stored.provider), family(integration.provider)} do
      {nil, _destination} -> {:error, :recurring_event}
      {family, family} -> {:ok, family}
      _different -> {:error, :cross_provider_series}
    end
  end

  # The CalDAV family is recognised as `Occurrence.series_family/1`
  # recognises it, so a series it offers to move is one this can move.
  defp family(provider) do
    cond do
      ProviderConfig.caldav_based?(provider) -> :caldav
      to_string(provider) == "google" -> :google
      to_string(provider) == "outlook" -> :outlook
      true -> nil
    end
  end

  defp calendar(integration, calendar_id) do
    case EventMove.destination_calendar_id(integration, calendar_id) do
      nil -> {:error, :no_destination_calendar}
      calendar_id -> {:ok, calendar_id}
    end
  end

  @spec write(family(), transfer()) :: {:ok, written()} | {:error, term()}
  defp write(:caldav, %{address: {:resource, href}, stored: stored} = transfer) do
    source = %{
      integration_id: stored.calendar_integration_id,
      href: href,
      document: stored.raw_ical,
      etag: stored.etag
    }

    destination = %{integration_id: transfer.integration.id, calendar_path: transfer.calendar_id}

    with {:ok, moved} <- CalendarEvents.move_caldav_series(transfer.user_id, source, destination) do
      {:ok,
       %{uid: moved.uid, id: moved.href, calendar_id: moved.calendar_path, source: moved.source}}
    end
  end

  defp write(:google, %{address: {:master, master_id}, stored: stored} = transfer) do
    source = %{
      integration_id: stored.calendar_integration_id,
      calendar_id: stored.provider_calendar_id || "primary",
      master_id: master_id
    }

    destination = %{integration_id: transfer.integration.id, calendar_id: transfer.calendar_id}
    CalendarEvents.move_google_series(transfer.user_id, source, destination)
  end

  defp write(:outlook, %{address: {:master, master_id}, stored: stored} = transfer) do
    source = %{
      integration_id: stored.calendar_integration_id,
      calendar_id: stored.provider_calendar_id || "primary",
      master_id: master_id
    }

    destination = %{integration_id: transfer.integration.id, calendar_id: transfer.calendar_id}
    CalendarEvents.move_outlook_series(transfer.user_id, source, destination)
  end

  # The steps every writer shares once the destination `integration` holds
  # the series, as `written` describes it (see *After the write*).
  defp settle(user_id, stored, integration, written) do
    source_id = stored.calendar_integration_id
    context = [user_id: user_id, calendar_integration_id: source_id]

    # Planned while the series' video rooms still hang off the source,
    # where the plan looks for a recorded room to tell whether the video
    # travels with the series.
    carried = SeriesCarry.plan(user_id, stored, {:moved, integration.id, written})

    after_move("move the series' video rooms", context, fn ->
      :ok =
        EventVideoRooms.series_moved(
          stored,
          integration.id,
          written.uid,
          written.id,
          written.calendar_id
        )
    end)

    after_move("delete the series' cached rows", context, fn ->
      {:ok, address} = Occurrence.series_address(stored)
      :ok = EventDeletion.delete_series_rows(source_id, address)
    end)

    SeriesCarry.carry(carried)

    after_move("invalidate cached availability", context, fn ->
      AvailabilityCache.invalidate_for_user(user_id)
    end)

    after_move("request a sync", context, fn ->
      SeriesEdit.request_sync(integration.provider, integration.id)

      if source_id != integration.id,
        do: SeriesEdit.request_sync(stored.provider, source_id)
    end)

    {:ok, moved(written, integration.id)}
  end

  defp moved(%{uid: uid, source: :removed}, integration_id),
    do: %{uid: uid, integration_id: integration_id}

  defp moved(%{uid: uid, source: :left_behind}, integration_id),
    do: %{uid: uid, integration_id: integration_id, source: :left_behind}

  defp after_move(step, context, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error(
        "Calendar grid series move: local cleanup failed after the series was moved",
        [
          step: step,
          error: LogFormat.reason(error),
          stacktrace: LogFormat.stacktrace(__STACKTRACE__)
        ] ++ context
      )

      :ok
  end
end
