defmodule Tymeslot.CalendarGrid.DebugSeriesDomainTest do
  @moduledoc """
  The debug calendar stands in for a CalDAV calendar towards the grid's
  domain: a repeating debug event, synced into the cache, is deleted and
  edited through `EventDeletion` and `SeriesEdit` exactly as a CalDAV series
  is, and what the domain does after each write (keeping siblings, handing a
  split's video room on, the series' wall clock) follows from the debug
  calendar's answers.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Test.ClockHelpers, only: [freeze_clock: 1]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module,
        do: Application.put_env(:tymeslot, :calendar_module, previous_module),
        else: Application.delete_env(:tymeslot, :calendar_module)
    end)

    freeze_clock(~U[2026-10-14 12:00:00Z])
    start_supervised!(DebugStore)
    DebugStore.set_pattern(:empty)

    # Mondays at 09:00 in Warsaw from 5 October 2026; the clocks go back on
    # 25 October, so 09:00 is 07:00 UTC before it and 08:00 UTC after.
    DebugStore.put_event(%{
      uid: "standup",
      summary: "Standup",
      all_day: false,
      timezone: "Europe/Warsaw",
      start_time: ~U[2026-10-05 07:00:00Z],
      end_time: ~U[2026-10-05 07:15:00Z],
      recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
    })

    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "debug", is_active: true)
    sync(integration)

    %{user: user, integration: integration}
  end

  # The debug sync, over the window every sync reads.
  defp sync(integration) do
    {range_start, range_end} = Sync.window()

    {:ok, raw} =
      DebugCalendarProvider.list_events(%{user_id: integration.user_id},
        start_time: range_start,
        end_time: range_end
      )

    {:ok, events} =
      DebugCalendarProvider.normalise_events(raw, %{
        calendar_integration_id: integration.id,
        provider_calendar_id: "default",
        synced_at: DateTime.utc_now()
      })

    :ok = Sync.persist_normalised_events(integration, events)
  end

  defp row(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    row
  end

  defp cached?(integration, uid),
    do: match?({:ok, _row}, ProviderCalendarEventQueries.get_by_uid(integration.id, uid))

  test "deleting one occurrence keeps its siblings cached, on the series' new document", %{
    user: user,
    integration: integration
  } do
    occurrence = row(integration, "standup_20261019T090000")

    assert {:ok, _deleted} = Changes.delete_event(user.id, occurrence, :occurrence)

    refute cached?(integration, "standup_20261019T090000")
    sibling = row(integration, "standup_20261026T090000")
    assert sibling.raw_ical =~ "EXDATE;TZID=Europe/Warsaw:20261019T090000"
  end

  test "a this-and-following edit records the tail and hands the series' room to it", %{
    user: user,
    integration: integration
  } do
    talk = insert(:video_integration, user: user, provider: "nextcloud_talk")

    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        provider: "nextcloud_talk",
        calendar_integration_id: integration.id,
        event_uid: "standup",
        provider_event_id: "debug:standup",
        room_id: "room-standup",
        lobby_opens_at: ~U[2026-10-05 06:45:00Z],
        ends_at: ~U[2026-12-28 08:15:00Z]
      })

    occurrence = row(integration, "standup_20261019T090000")

    assert {:ok, _updated} =
             Changes.update_event(user.id, occurrence, %{summary: "Planning"},
               recurrence_scope: :following
             )

    assert [tail_uid] = Map.keys(DebugStore.snapshot().events) -- ["standup"]

    room = Repo.reload!(room)
    assert {room.event_uid, room.provider_event_id} == {tail_uid, "debug:#{tail_uid}"}
  end

  test "an all-events move across the clock change and to another day keeps the wall clock", %{
    user: user,
    integration: integration
  } do
    occurrence = row(integration, "standup_20261019T090000")

    # Monday 09:00 to Tuesday 10:00, Warsaw summer time.
    assert {:ok, _updated} =
             Changes.update_event(
               user.id,
               occurrence,
               %{start_at: ~U[2026-10-20 08:00:00Z], end_at: ~U[2026-10-20 08:15:00Z]},
               recurrence_scope: :all
             )

    sync(integration)

    # Tuesday 3 November 10:00 is winter time, 09:00 UTC.
    moved = row(integration, "standup_20261103T100000")
    assert moved.start_at == ~U[2026-11-03 09:00:00.000000Z]
    assert Date.day_of_week(DateTime.to_date(moved.start_at)) == 2
    assert moved.recurrence_rule =~ "BYDAY=TU"
  end
end
