defmodule TymeslotWeb.Live.Scheduling.OfferedTimesBookingJourneyTest do
  @moduledoc """
  A one-to-one meeting type with fixed dates on its public booking page: a
  visitor finds only the times the host offered, outside the weekly hours
  as much as inside them, books one, and the next visitor no longer finds
  it.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.{MeetingTypeSchema, OfferedTimes}
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
    test "#{theme_name}: a visitor books an offered time, which is then gone", %{conn: conn} do
      %{user: user, profile: profile} =
        seed_booking_account(unquote(theme_id), "offered-#{unquote(theme_id)}", @timezone)

      # The account's weekly hours are 09:00 to 17:00 every day; its type
      # now offers two evening times instead.
      meeting_type =
        MeetingTypeSchema
        |> Repo.get_by!(user_id: user.id)
        |> Changeset.change(fixed_dates: true, max_participants: 1)
        |> Repo.update!()

      day = Date.add(Date.utc_today(), 9)
      iso = Date.to_iso8601(day)

      for time <- [~T[18:00:00], ~T[19:30:00]] do
        {:ok, _offered} = OfferedTimes.add(meeting_type, user.id, DateTime.new!(day, time))
      end

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

      BookingDriver.book(view,
        date: iso,
        time: "6:00 PM",
        attendee: %{name: "Ada Lovelace", email: "offered-#{unquote(theme_id)}@example.com"}
      )

      wait_until(fn -> Repo.get_by(MeetingSchema, organizer_user_id: user.id) end)
      meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)

      assert meeting.status == :confirmed
      assert DateTime.compare(meeting.start_time, DateTime.new!(day, ~T[18:00:00])) == :eq

      # The next visitor finds only the other offered time on that day: not
      # the booked one, and none of the weekly hours'.
      AvailabilityCache.clear_all()
      {:ok, next_view, _html} = live(build_conn(), "/#{profile.username}?timezone=#{@timezone}")
      [slug] = BookingDriver.meeting_types(next_view)
      BookingDriver.choose_meeting_type(next_view, slug)

      assert BookingDriver.pick_first_slot(next_view, on: iso) == {iso, "7:30 PM"}
    end
  end
end
