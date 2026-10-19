defmodule Tymeslot.Availability.OfferCalendarCacheTest do
  @moduledoc """
  How often the booking page reads the host's connected calendars.

  The page used to read the whole booking window afresh from every provider
  on each date the booker clicked, although the month view had fetched the
  identical window moments before. A date click now reads the same cached
  window as the month view, so slots can be up to the cache's lifetime old;
  the booking submit still reads the calendars afresh, and that read is what
  refuses a slot taken in the meantime.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  @timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    AvailabilityCache.clear_all()
    on_exit(&AvailabilityCache.clear_all/0)

    %{user: user, profile: profile} = create_bookable_profile(timezone: @timezone)

    meeting_type =
      insert(:meeting_type, user: user, name: "Intro", duration_minutes: 60, is_active: true)

    date = next_bookable_weekday()

    stub_calendar(self(), [])

    %{
      user: user,
      meeting_type: meeting_type,
      date: date,
      request: %{profile: profile, user_timezone: @timezone, meeting_type: meeting_type}
    }
  end

  test "two date clicks within the cache lifetime read the host's calendars once", context do
    %{request: request, date: date} = context

    assert {:ok, [_first | _rest]} = Offer.slots_for_date(request, Date.to_iso8601(date), 60)
    assert {:ok, _slots} = Offer.slots_for_date(request, Date.to_iso8601(Date.add(date, 1)), 60)

    assert_received {:fetched, _start_date, _end_date}
    refute_received {:fetched, _start_date, _end_date}
  end

  test "a date click reuses the window the month view already read", context do
    %{request: request, date: date} = context

    assert {:ok, %{}} = Offer.days_in_range(request, date, Date.add(date, 6), 60)
    assert_received {:fetched, _start_date, _end_date}

    assert {:ok, [_first | _rest]} = Offer.slots_for_date(request, Date.to_iso8601(date), 60)
    refute_received {:fetched, _start_date, _end_date}
  end

  test "the submit reads the calendars afresh after a date click", context do
    %{request: request, date: date} = context

    {:ok, offered} = Offer.slots_for_date(request, Date.to_iso8601(date), 60)
    assert "11:00 AM" in offered
    assert_received {:fetched, _start_date, _end_date}

    assert {:ok, _meeting} = Orchestrator.submit_booking(submit_params(context))
    assert_received {:fetched, _start_date, _end_date}
  end

  test "the submit refuses a slot taken in the host's calendar since the date click",
       context do
    %{request: request, date: date} = context

    {:ok, offered} = Offer.slots_for_date(request, Date.to_iso8601(date), 60)
    assert "11:00 AM" in offered
    assert_received {:fetched, _start_date, _end_date}

    # The host's calendar gains an event at 11:00 after the page read it.
    start_time = DateTime.new!(date, ~T[11:00:00], @timezone)

    stub_calendar(self(), [
      TestMocks.mock_calendar_event(
        start_time: start_time,
        end_time: DateTime.add(start_time, 60, :minute)
      )
    ])

    # The date view still answers from the window it read.
    {:ok, offered_again} = Offer.slots_for_date(request, Date.to_iso8601(date), 60)
    assert "11:00 AM" in offered_again
    refute_received {:fetched, _start_date, _end_date}

    assert {:error, :slot_taken} = Orchestrator.submit_booking(submit_params(context))
    assert_received {:fetched, _start_date, _end_date}
  end

  defp submit_params(%{user: user, meeting_type: meeting_type, date: date}) do
    %{
      form_data: %{"name" => "Attendee", "email" => "attendee@example.com", "message" => ""},
      meeting_params: %{
        date: Date.to_iso8601(date),
        time: "11:00",
        duration: "60min",
        user_timezone: @timezone,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }
    }
  end

  defp stub_calendar(test_pid, events) do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
      send(test_pid, {:fetched, start_date, end_date})
      {:ok, events}
    end)
  end
end
