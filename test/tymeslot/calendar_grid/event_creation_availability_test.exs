defmodule Tymeslot.CalendarGrid.EventCreationAvailabilityTest do
  @moduledoc """
  Pins what drawing an event on the calendar grid does to the organiser's
  cached availability.

  Blocking an hour on the grid is the ordinary way a host makes themselves
  unavailable, so the booking page must stop offering that time straight
  away. Availability is memoised per user for the cache's TTL, and the events
  behind it are fetched live from the providers, so the create has to drop the
  organiser's entries or the page keeps offering the slot until they expire.

  A create the provider refused and the offline queue swallowed is the other
  half of the contract: that event exists on no server yet, the slot really is
  still free, and dropping the cache would buy nothing but a slower next page
  load. These tests assert both directions.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Availability.Offer
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "gridcreate", timezone: "Etc/UTC")

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 90,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    # A single bookable hour a day, so one grid event blocks the whole day and
    # the day-level answer the booking page renders flips from true to false.
    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00]
      )
    end)

    %{user: user, profile: profile, date: Date.add(Date.utc_today(), 10)}
  end

  test "a slot blocked on the grid stops being offered on the booking page",
       %{user: user, profile: profile, date: date} do
    integration = insert(:calendar_integration, user: user, is_active: true)
    blocked = start_supervised!({Agent, fn -> [] end})

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, Agent.get(blocked, & &1)}
    end)

    # The provider only reports the event once the grid create has written it,
    # which is what the invalidation has to make the page notice.
    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
      Agent.update(blocked, fn _none -> [provider_event(event_data)] end)
      {:ok, "uid-grid-block-1"}
    end)

    assert offered?(profile, date), "expected the free hour to be offered before the block"

    assert {:ok, _result} =
             EventCreation.run_create_event(create_payload(user, integration, date))

    refute offered?(profile, date),
           "the hour the host blocked on the grid is still being offered to bookers"
  end

  test "a create the provider refused and the queue swallowed leaves the cache warm",
       %{user: user, profile: profile, date: date} do
    integration =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    test_pid = self()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      send(test_pid, :provider_fetch)
      {:ok, []}
    end)

    expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
      {:error, :network_error}
    end)

    assert offered?(profile, date)
    assert provider_fetch_count() == 1

    assert {:error, %{reason: :network_error, retry: :queued}} =
             EventCreation.run_create_event(create_payload(user, integration, date))

    # The queued event is on no calendar server, so the hour is still free and
    # the memoised answer is still right. Dropping it would cost the next
    # booking page a provider round trip for nothing.
    assert offered?(profile, date)
    assert provider_fetch_count() == 0
  end

  defp create_payload(user, integration, date) do
    %{
      creating: %{
        title: "Focus block",
        integration_id: integration.id,
        calendar_id: "primary",
        attendees: [],
        video_integration_id: nil
      },
      user_id: user.id,
      start_at: DateTime.new!(date, ~T[09:00:00], "Etc/UTC"),
      end_at: DateTime.new!(date, ~T[10:00:00], "Etc/UTC")
    }
  end

  # The day-level answer the booking page's month grid renders, which is the
  # surface `AvailabilityCache` memoises.
  defp offered?(profile, date) do
    request = %{profile: profile, user_timezone: "Etc/UTC", meeting_type: nil}

    assert {:ok, days} = Offer.days_in_range(request, date, date, 60)
    Map.fetch!(days, Date.to_iso8601(date))
  end

  # The event as the provider would report it back on the next read.
  defp provider_event(event_data) do
    %{
      uid: event_data.uid,
      summary: event_data.summary,
      start_time: event_data.start_time,
      end_time: event_data.end_time,
      status: "confirmed",
      transparency: "opaque"
    }
  end

  # Drains and counts the fetch notifications the stub sent, so the count is
  # of round trips actually made rather than of anything the cache reports
  # about itself.
  defp provider_fetch_count(acc \\ 0) do
    receive do
      :provider_fetch -> provider_fetch_count(acc + 1)
    after
      0 -> acc
    end
  end
end
