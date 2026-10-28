defmodule TymeslotWeb.Live.Scheduling.ExtraAvailabilityBookingJourneyTest do
  @moduledoc """
  An organiser opens a date their weekly hours leave closed with an extra
  available time; a visitor finds a time from it on the public booking page
  and books it. The meeting in the database, at exactly the instant picked,
  is the witness.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Availability.{AvailabilityScheduleSchema, ExtraAvailability, WeeklySchedule}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  for {theme_id, theme_name} <- [{"1", "Quill"}, {"2", "Rhythm"}] do
    @tag :capture_log
    test "#{theme_name}: a visitor books a time from an extra time on a closed weekday",
         %{conn: conn} do
      %{user: user, profile: profile} =
        seed_booking_account(unquote(theme_id), "extra-#{unquote(theme_id)}", @timezone)

      schedule = Repo.get_by!(AvailabilityScheduleSchema, profile_id: profile.id)

      # Nine days out: inside the 30-day window, and never today. Its weekday
      # is switched off, so only the extra time opens it.
      day = Date.add(Date.utc_today(), 9)

      {:ok, _closed} =
        WeeklySchedule.upsert_day_availability(schedule.id, Date.day_of_week(day), %{
          is_available: false
        })

      {:ok, _extra} =
        ExtraAvailability.add(
          schedule,
          %{date: day, start_time: ~T[18:00:00], end_time: ~T[19:00:00]},
          Date.utc_today()
        )

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

      BookingDriver.book(view,
        date: Date.to_iso8601(day),
        time: "6:00 PM",
        attendee: %{name: "Ada Lovelace", email: "extra-#{unquote(theme_id)}@example.com"}
      )

      wait_until(fn -> Repo.get_by(MeetingSchema, organizer_user_id: user.id) end)
      meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)

      assert meeting.status == "confirmed"
      assert DateTime.compare(meeting.start_time, DateTime.new!(day, ~T[18:00:00])) == :eq
    end
  end
end
