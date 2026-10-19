defmodule Tymeslot.Availability.OfferBookingRaceTest do
  @moduledoc """
  A booking committed while a booking page is still working out which days
  are free.

  The page's computation read the host's bookings before the new one
  existed, so its answer offers the time just taken. The booking invalidates
  the host's cached availability, and that has to reach the computation
  still in flight: its stale answer may go back to the page that asked, but
  it must not be stored for the next visitor.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings
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
  @handler_id "offer-booking-race-test"

  setup do
    TestMocks.setup_all_mocks()
    AvailabilityCache.clear_all()
    on_exit(&AvailabilityCache.clear_all/0)
    on_exit(fn -> :telemetry.detach(@handler_id) end)

    # One free hour a day, so a single booking fills the day.
    %{user: user, profile: profile} =
      create_bookable_profile(
        timezone: @timezone,
        hours: %{is_available: true, start_time: ~T[11:00:00], end_time: ~T[12:00:00]}
      )

    meeting_type =
      insert(:meeting_type, user: user, name: "Intro", duration_minutes: 60, is_active: true)

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    %{
      user: user,
      meeting_type: meeting_type,
      date: next_bookable_weekday(),
      request: %{profile: profile, user_timezone: @timezone, meeting_type: meeting_type}
    }
  end

  test "the next load does not offer a time booked while the page was computing", context do
    %{request: request, date: date} = context
    day = Date.to_iso8601(date)

    hold_after_reading_bookings(self())

    in_flight = Task.async(fn -> Offer.days_in_range(request, date, date, 60) end)

    # The page has read the host's bookings and has not yet answered.
    assert_receive {:read_bookings, computing}, 5_000

    assert {:ok, _meeting} = Orchestrator.submit_booking(submit_params(context))

    send(computing, :continue)
    assert {:ok, %{^day => true}} = Task.await(in_flight)

    assert {:ok, %{^day => false}} = Offer.days_in_range(request, date, date, 60)
  end

  # Holds the first process other than the test's own, once it has read the
  # host's meetings, until the test lets it go. The query event is emitted
  # in the process that ran the query, after it returned.
  #
  # Only the first such read is held, whichever process makes it: the flag is
  # an atomic shared by every process, not one process's dictionary, so a
  # read from another process (a task the offer spawns) is not held as well
  # and left waiting for a release that never comes.
  defp hold_after_reading_bookings(test_pid) do
    held = :atomics.new(1, [])

    :telemetry.attach(
      @handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() != test_pid and metadata[:source] == "meetings" and
             :atomics.compare_exchange(held, 1, 0, 1) == :ok do
          send(test_pid, {:read_bookings, self()})

          receive do
            :continue -> :ok
          end
        end
      end,
      nil
    )
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
end
