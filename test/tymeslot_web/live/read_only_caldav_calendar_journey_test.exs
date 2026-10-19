defmodule TymeslotWeb.ReadOnlyCalDAVCalendarJourneyTest do
  @moduledoc """
  A calendar shared with the host read-only (a team rota, a partner's diary,
  a subscribed calendar) and selected on their CalDAV integration cannot take
  a booking, but its events block time: the booking page leaves a busy slot
  out, and a booker who picked that slot before the event appeared is refused
  on submit. One the server will not let Tymeslot read blocks every slot,
  since its busy time is unknown.

  The `:calendar_module` seam points back at the runtime module, so the whole
  read path runs (`ClientManager`, the CalDAV provider, the REPORT parse) and
  only the HTTP client answers in the server's place.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Infrastructure.ProviderBreakers
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :set_mox_global
  setup :verify_on_exit!

  @base_url "https://dav.example.com"
  @bookings "/calendars/host/bookings/"
  @rota "/calendars/host/rota/"
  @time_slot "button[data-testid='time-slot']"

  setup do
    previous = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)
    on_exit(fn -> Application.put_env(:tymeslot, :calendar_module, previous) end)

    TestMocks.setup_email_mocks()
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    ProviderBreakers.reset_all_hosts()

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, recaptcha) end)

    # What the rota holds, changed by a test while the page is open.
    {:ok, rota} = Agent.start_link(fn -> [] end)

    stub(Tymeslot.HTTPClientMock, :request, fn :report, url, _body, _headers, _opts ->
      events = if URI.parse(url).path == @rota, do: Agent.get(rota, & &1), else: []
      {:ok, %Req.Response{status: 207, body: multistatus(events)}}
    end)

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "rota-host",
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
      base_url: @base_url,
      calendar_paths: [@bookings, @rota],
      default_booking_calendar_id: @bookings,
      calendar_list: [
        %{id: @bookings, path: @bookings, name: "Bookings", selected: true},
        %{id: @rota, path: @rota, name: "Team rota", selected: true, read_only: true}
      ]
    )

    %{profile: profile, rota: rota, tomorrow: Date.add(Date.utc_today(), 1)}
  end

  test "a busy event in the read-only calendar hides its slot on the booking page", %{
    conn: conn,
    profile: profile,
    rota: rota,
    tomorrow: tomorrow
  } do
    put_rota_event(rota, tomorrow, ~T[10:00:00], ~T[11:00:00])

    slots = offered_slots(conn, profile, tomorrow)

    assert "9:30 AM" in slots
    refute "10:00 AM" in slots
    refute "10:30 AM" in slots
    assert "11:00 AM" in slots
  end

  test "submitting a slot the read-only calendar has since filled is refused", %{
    conn: conn,
    profile: profile,
    rota: rota,
    tomorrow: tomorrow
  } do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    view = walk_to_booking_form(view, "Etc/UTC")

    # The walk picked one of tomorrow's times while the rota was empty; the
    # rota then fills the whole of tomorrow's working day, whichever it was.
    put_rota_event(rota, tomorrow, ~T[09:00:00], ~T[17:00:00])

    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{
        "name" => "Late Booker",
        "email" => "late-booker@example.com",
        "message" => "",
        "website" => ""
      }
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    assert render(view) =~ "no longer available"
    refute render(view) =~ "Meeting Confirmed!"
    assert Repo.aggregate(MeetingSchema, :count, :id) == 0
  end

  # A rota the server will not let Tymeslot read has unknown busy time, not
  # none: the booking page must not offer slots built from the bookings
  # calendar alone, which would hide whatever the rota holds.
  test "a calendar the server will not read offers no slots", %{
    conn: conn,
    profile: profile,
    tomorrow: tomorrow
  } do
    stub(Tymeslot.HTTPClientMock, :request, fn :report, url, _body, _headers, _opts ->
      if URI.parse(url).path == @rota,
        do: {:ok, %Req.Response{status: 403, body: ""}},
        else: {:ok, %Req.Response{status: 207, body: multistatus([])}}
    end)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    view |> element("button[data-testid='duration-option']") |> render_click()
    view |> element("button[data-testid='next-step']") |> render_click()

    eventually(fn -> :sys.get_state(view.pid).socket.assigns[:availability_status] == :error end)

    day = "button[data-testid='calendar-day'][phx-value-date='#{tomorrow}']"
    show_month(view, tomorrow)
    view |> element(day) |> render_click()
    eventually(fn -> :sys.get_state(view.pid).socket.assigns[:loading_slots] == false end)

    refute has_element?(view, @time_slot)
  end

  defp put_rota_event(rota, date, from, to) do
    event =
      {"rota-#{from}", DateTime.new!(date, from, "Etc/UTC"), DateTime.new!(date, to, "Etc/UTC")}

    Agent.update(rota, &[event | &1])
  end

  # The times the schedule step offers for `date`, as the booker sees them.
  defp offered_slots(conn, profile, date) do
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
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute(@time_slot, "phx-value-time")
  end

  defp multistatus(events) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    #{Enum.map_join(events, &event_response/1)}
    </D:multistatus>
    """
  end

  defp event_response({uid, start_at, end_at}) do
    """
    <D:response>
      <D:href>#{@rota}#{uid}.ics</D:href>
      <D:propstat>
        <D:prop>
          <D:getetag>"etag-#{uid}"</D:getetag>
          <C:calendar-data>BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//Test//EN
    BEGIN:VEVENT
    UID:#{uid}
    DTSTART:#{ical_time(start_at)}
    DTEND:#{ical_time(end_at)}
    SUMMARY:On call
    END:VEVENT
    END:VCALENDAR</C:calendar-data>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
    """
  end

  defp ical_time(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")
end
