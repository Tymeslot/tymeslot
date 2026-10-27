defmodule TymeslotWeb.Scheduling.BookingUnverifiableTest do
  @moduledoc """
  A booking refused at submit because the organiser's calendars could not
  all be read tells the booker to try again, and is not logged as a failure:
  the check worked as meant and already logged its cause.
  """

  use TymeslotWeb.LiveCase, async: false

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  @moduletag :bookings
  @moduletag :live

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "unverifiable", timezone: "America/New_York")

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    insert(:calendar_integration, user: user, provider: "google", is_active: true)
    event_type = insert(:meeting_type, user: user, duration_minutes: 30, is_active: true)

    for day_of_week <- 1..7 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    %{profile: profile, event_type: event_type}
  end

  test "is refused with a try-again message and no error logged",
       %{conn: conn, profile: profile, event_type: event_type} do
    view = navigate_to_booking_form(conn, profile, event_type)

    # The calendars were readable when the times were offered and are not
    # when the booking is submitted.
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:error, :all_calendars_unavailable}
    end)

    log =
      capture_log([level: :error], fn ->
        view
        |> form("form[data-testid='booking-form']", %{
          "booking" => %{"name" => "Ada Booker", "email" => "ada@example.com"}
        })
        |> render_submit()

        eventually(fn -> assert render(view) =~ "check the host" end)
      end)

    refute log =~ "Failed to create meeting appointment"
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end
end
