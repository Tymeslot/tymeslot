defmodule TymeslotWeb.Live.Scheduling.BookingUtmFlowTest do
  @moduledoc """
  End-to-end integration test for UTM/tracking parameter threading
  through the public scheduling flow.

  Verifies that UTM and arbitrary tracking params present on the landing
  URL survive the four-step booking flow (overview → schedule → booking)
  and are persisted on the created meeting. This is what makes the
  analytics dashboard's source attribution work — without this thread,
  the page view event would carry the UTMs but the meeting row would not.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # Disable reCAPTCHA so the booking form can be submitted without a
    # token. The branches under test (params threading + persistence)
    # are orthogonal to the security gate.
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "utm-host",
        booking_theme: "1",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "UTM Chat",
        is_active: true
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, meeting_type: meeting_type, user: user}
  end

  @tag :capture_log
  # NOTE: end-to-end coverage of `Referer` → `meeting.referrer_host` requires
  # `:x_headers` connect_info propagation that LiveView's test helpers do not
  # provide for request headers set via `put_req_header/3`. The host-parsing
  # half is unit-tested in `Tymeslot.Analytics.UtmExtractorTest`. Full HTTP
  # coverage would require a Wallaby/browser-driven test.

  @tag :capture_log
  test "UTM and tracking params from the landing URL persist on the created meeting", %{
    conn: conn,
    profile: profile,
    meeting_type: meeting_type
  } do
    # The booking flow lands on the schedule step directly from
    # /:username/:slug, so the UTM params sit on that URL. The shared
    # scheduling LiveView macro must capture them in socket assigns at
    # mount and thread them into meeting_params at submit.
    conn = put_req_header(conn, "user-agent", "Mozilla/5.0 (Macintosh) Chrome/126.0.0.0")

    view = navigate_to_booking_form_with_tracking(conn, profile, meeting_type)

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "UTM User",
        "email" => "utm-user@example.com",
        "message" => "Hi from LinkedIn"
      }
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    [meeting] = MeetingListQueries.list_meetings_by_attendee_email("utm-user@example.com")

    assert meeting.utm_source == "linkedin"
    assert meeting.utm_medium == "social"
    assert meeting.utm_campaign == "spring"
    assert meeting.tracking_params == %{"ref" => "newsletter"}

    # The cookieless join key is captured at mount and persisted on the booking,
    # letting analytics join this meeting back to its page-view for conversion.
    assert meeting.visitor_hash =~ ~r/^[0-9a-f]{64}$/
  end

  @tag :capture_log
  test "no UTM or tracking params are persisted when booking analytics is disabled", %{
    conn: conn,
    profile: profile,
    meeting_type: meeting_type
  } do
    Application.put_env(:tymeslot, :booking_analytics_enabled, false)
    on_exit(fn -> Application.put_env(:tymeslot, :booking_analytics_enabled, true) end)

    conn = put_req_header(conn, "user-agent", "Mozilla/5.0 (Macintosh) Chrome/126.0.0.0")

    view = navigate_to_booking_form_with_tracking(conn, profile, meeting_type)

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "No UTM User",
        "email" => "no-utm-user@example.com",
        "message" => "Hi from a campaign"
      }
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    [meeting] = MeetingListQueries.list_meetings_by_attendee_email("no-utm-user@example.com")

    assert is_nil(meeting.utm_source)
    assert is_nil(meeting.utm_medium)
    assert is_nil(meeting.utm_campaign)
    assert meeting.tracking_params == %{}
    # Feature off → no visitor hash captured or persisted.
    assert is_nil(meeting.visitor_hash)
  end

  # Mirrors `Tymeslot.BookingTestHelpers.navigate_to_booking_form/3` but
  # lands on the schedule URL with UTM params attached. We can't use the
  # shared helper directly because it visits `/:username` (the overview
  # page) — the public scheduling entry where a campaign link lives is
  # `/:username/:slug`, which lets us pin the URL the booker actually
  # arrives on.
  defp navigate_to_booking_form_with_tracking(conn, profile, meeting_type) do
    timezone = profile.timezone
    slug = MeetingTypes.to_slug(meeting_type)

    # Drive the landing URL the way a campaign would: only UTM and a
    # custom tracking param, no scheduling-internal query string. The
    # LiveView falls back to the profile timezone when no `?timezone=`
    # is provided.
    query =
      URI.encode_query(%{
        "utm_source" => "linkedin",
        "utm_medium" => "social",
        "utm_campaign" => "spring",
        "ref" => "newsletter"
      })

    {:ok, view, _html} = live(conn, "/#{profile.username}/#{slug}?#{query}")

    today = timezone |> DateTime.now!() |> DateTime.to_date()
    target_date = Date.add(today, 1)
    date_str = Date.to_string(target_date)

    if target_date.month != today.month || target_date.year != today.year do
      view |> element("button[phx-click='next_month']") |> render_click()
    end

    wait_until(fn ->
      has_element?(view, "button.calendar-day[phx-value-date='#{date_str}']:not([disabled])")
    end)

    view |> element("button.calendar-day[phx-value-date='#{date_str}']") |> render_click()

    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    slot =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("button.time-slot-button", "phx-value-time")
      |> List.first() ||
        flunk("Expected at least one available time slot button after selecting a date")

    view |> element("button.time-slot-button[phx-value-time='#{slot}']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()

    view
  end
end
