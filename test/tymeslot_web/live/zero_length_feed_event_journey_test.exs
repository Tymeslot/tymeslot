defmodule TymeslotWeb.ZeroLengthFeedEventJourneyTest do
  @moduledoc """
  A subscribed calendar feed entry with a start and no end (no DTEND, no
  DURATION) marks a moment, as RFC 5545 §3.6.1 reads it: it is cached ending
  where it starts, the host sees it on their calendar, and it takes no time
  from the booking page, where a slot running across it can still be booked.
  A timed entry in the same feed blocks its slots as before.

  Driven through the real sync worker and the real read path; only HTTP is
  stubbed: the feed's response, and a CalDAV calendar that takes the
  bookings and holds nothing.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.BookingTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers
  import Tymeslot.TestHelpers.Eventually

  alias Plug.Conn
  alias Plug.Test
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  @feed_url "https://feeds.example.com/secret-address/rota.ics"
  @bookings "/calendars/host/bookings/"
  @time_slot "button[data-testid='time-slot']"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :calendar_module, Operations)

    TestMocks.setup_email_mocks()
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, recaptcha) end)

    tomorrow = Date.add(Date.utc_today(), 1)
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    profile =
      insert(:profile,
        user: user,
        username: "moment-host",
        booking_theme: "1",
        timezone: "Etc/UTC"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    for day_of_week <- 1..7 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    insert(:meeting_type, user: user, name: "Chat", duration_minutes: 30, is_active: true)

    insert(:calendar_integration,
      user: user,
      provider: "caldav",
      base_url: "https://dav.example.com",
      calendar_paths: [@bookings],
      default_booking_calendar_id: @bookings,
      calendar_list: [%{id: @bookings, path: @bookings, name: "Bookings", selected: true}]
    )

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt(@feed_url),
        is_active: true
      )

    # 10:15 sits inside the 10:00 slot, so only an entry that takes no time
    # leaves that slot free; 14:00 to 15:00 is the control that does block.
    moment = DateTime.new!(tomorrow, ~T[10:15:00], "Etc/UTC")

    stub_feed("""
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Example Corp//Publisher//EN
    BEGIN:VEVENT
    UID:moment@example.com
    DTSTART:#{ical_time(moment)}
    SUMMARY:Deadline
    END:VEVENT
    BEGIN:VEVENT
    UID:busy@example.com
    DTSTART:#{ical_time(DateTime.new!(tomorrow, ~T[14:00:00], "Etc/UTC"))}
    DTEND:#{ical_time(DateTime.new!(tomorrow, ~T[15:00:00], "Etc/UTC"))}
    SUMMARY:Rota
    END:VEVENT
    END:VCALENDAR
    """)

    assert :ok =
             perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

    # The feed is cached; from here the booking calendar answers over HTTP.
    Application.put_env(:tymeslot, :http_client_module, Tymeslot.HTTPClientMock)

    stub(Tymeslot.HTTPClientMock, :request, fn :report, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 207, body: empty_multistatus()}}
    end)

    stub(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 201, headers: %{"etag" => ["\"booked\""]}}}
    end)

    %{
      user: user,
      profile: profile,
      integration: integration,
      tomorrow: tomorrow,
      moment: moment
    }
  end

  test "the entry is cached ending where it starts", %{integration: integration, moment: moment} do
    cached =
      [integration.id]
      |> ProviderCalendarEventQueries.list_for_range(
        DateTime.add(moment, -1, :day),
        DateTime.add(moment, 1, :day)
      )
      |> Enum.find(&(&1.uid == "moment@example.com"))

    assert cached.all_day == false
    assert DateTime.compare(cached.start_at, moment) == :eq
    assert DateTime.compare(cached.end_at, moment) == :eq
  end

  test "the host sees the entry on their calendar", %{
    conn: conn,
    user: user,
    integration: integration,
    moment: moment
  } do
    freeze_clock(DateTime.add(moment, -2, :hour))
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    [cached] =
      [integration.id]
      |> ProviderCalendarEventQueries.list_for_range(moment, DateTime.add(moment, 1, :hour))
      |> Enum.filter(&(&1.uid == "moment@example.com"))

    assert has_element?(lv, "[id^='event-#{cached.id}-']")
  end

  test "the slot running across the entry is offered and can be booked", %{
    conn: conn,
    profile: profile,
    tomorrow: tomorrow
  } do
    view = open_day(conn, profile, tomorrow)
    slots = offered_slots(view)

    assert "10:00 AM" in slots
    assert "10:30 AM" in slots
    refute "2:00 PM" in slots
    refute "2:30 PM" in slots

    view |> element("#{@time_slot}[phx-value-time='10:00 AM']") |> render_click()
    view |> element("button[data-testid='next-step']") |> render_click()

    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{
        "name" => "Moment Booker",
        "email" => "moment-booker@example.com",
        "message" => "",
        "website" => ""
      }
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    assert render(view) =~ "Meeting Confirmed!"

    assert [%MeetingSchema{start_time: start_time}] = Repo.all(MeetingSchema)
    assert DateTime.compare(start_time, DateTime.new!(tomorrow, ~T[10:00:00], "Etc/UTC")) == :eq
  end

  defp stub_feed(body) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "text/calendar")
      |> Conn.send_resp(200, body)
    end)
  end

  defp open_day(conn, profile, date) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")

    view |> element("button[data-testid='duration-option']") |> render_click()
    view |> element("button[data-testid='next-step']") |> render_click()

    day = "button[data-testid='calendar-day'][phx-value-date='#{date}']"
    eventually(fn -> has_element?(view, "button[data-testid='calendar-day']") end)
    show_month(view, date)
    eventually(fn -> has_element?(view, day <> ":not([disabled])") end)
    view |> element(day) |> render_click()
    eventually(fn -> has_element?(view, @time_slot) end)

    view
  end

  defp offered_slots(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute(@time_slot, "phx-value-time")
  end

  defp empty_multistatus do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"></D:multistatus>
    """
  end

  defp ical_time(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")
end
