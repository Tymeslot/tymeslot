defmodule TymeslotWeb.E2E.VisitorTimezoneBookingTest do
  @moduledoc """
  A visitor whose browser is in another timezone than the host's books
  through the public page in a real browser: the page takes the zone the
  browser reports when the LiveView connects, shows the host's hours in it,
  and the time the visitor clicks is stored at the right UTC instant.

  The host works 9:00 to 17:00 in UTC (the default weekly schedule, its
  profile set to UTC). The browser is put in Asia/Kolkata, UTC+5:30 all
  year, so the shift is the same on every run date and its half hour cannot
  be mistaken for a whole-hour zone: the host's day reads 2:30 PM to the
  last start at 10:00 PM.

  The zone is set for this one browser session through chromedriver's
  DevTools passthrough (`POST /session/:id/goog/cdp/execute`, running
  `Emulation.setTimezoneOverride`), so `Intl` in the page reports it, as it
  would on a visitor's own machine. The override belongs to the session's
  tab and goes with it, so no other test sees it and no change to
  `BrowserCase` or the Chrome launch is needed.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.E2E.BookerSteps
  alias Wallaby.Element
  alias Wallaby.HTTPClient

  @moduletag :e2e
  @moduletag :bookings

  @visitor_zone "Asia/Kolkata"
  @email "kolkata-visitor@example.com"

  feature "a visitor in Kolkata sees the host's UTC hours in their own time and books one",
          %{session: session} do
    {username, slug} = create_utc_host()
    date = bookable_weekday()

    session =
      session
      |> resize_window(1280, 900)
      |> put_browser_timezone(@visitor_zone)
      |> visit("/#{username}/#{slug}")
      |> wait_for_live()

    # Chrome's ICU still names the zone by its old id, Asia/Calcutta; the
    # page normalises it to Asia/Kolkata, the id it stores (below).
    assert browser_zone(session) in [@visitor_zone, "Asia/Calcutta"]

    # The picker names the zone it detected, with its offset.
    assert_has(session, css("#timezone-picker", text: "Kolkata time (UTC+5:30)"))

    session = open_day(session, date)

    # The host's 9:00 to 17:00 UTC, every start shifted by five and a half
    # hours: the first at 2:30 PM, the last 30-minute meeting at 10:00 PM.
    times = day_times(session)
    assert List.first(times) == "2:30 PM"
    assert List.last(times) == "10:00 PM"
    assert length(times) == 16

    # What the visitor reads on the button.
    assert_has(session, css("[data-fact='time'][data-value='2:30 PM']", text: "02:30 PM"))

    session
    |> click(css("[data-fact='time'][data-value='2:30 PM']"))
    |> BookerSteps.click_next_step()
    |> assert_has(css("[data-testid='booking-form']"))
    |> fill_in(css("input[name='booking[name]']"), with: "Kolkata Visitor")
    |> fill_in(css("input[name='booking[email]']"), with: @email)
    |> click(css("[data-testid='submit-booking']"))
    |> assert_has(css("[data-testid='confirmation-heading']"))

    # 2:30 PM in Kolkata is 9:00 in UTC, the start of the host's day.
    meeting = Repo.get_by!(MeetingSchema, attendee_email: @email)
    assert meeting.start_time == DateTime.new!(date, ~T[09:00:00], "Etc/UTC")
    assert meeting.attendee_timezone == @visitor_zone
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  # A host in UTC with the default Monday-to-Friday 9:00-17:00 week, a
  # connected calendar and one 30-minute type. Returns its username and the
  # type's slug.
  defp create_utc_host do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)
    {:ok, profile} = Profiles.update_timezone(Profiles.get_profile(user.id), "Etc/UTC")

    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Kolkata Call",
        duration_minutes: 30,
        is_active: true
      })

    {profile.username, Slugs.to_slug(meeting_type)}
  end

  # The first weekday at least three days out, clear of any minimum notice,
  # so the whole of the host's day is still on offer.
  defp bookable_weekday do
    Date.utc_today()
    |> Date.add(3)
    |> Stream.iterate(&Date.add(&1, 1))
    |> Enum.find(&(Date.day_of_week(&1) in 1..5))
  end

  # ── Browser ────────────────────────────────────────────────────────────

  # Sets the zone the page's `Intl` reports, for this session's tab, through
  # chromedriver's passthrough to the DevTools protocol. Set before the first
  # visit, so the LiveView's connect params carry it.
  defp put_browser_timezone(session, zone) do
    {:ok, _response} =
      HTTPClient.request(:post, "#{session.session_url}/goog/cdp/execute", %{
        cmd: "Emulation.setTimezoneOverride",
        params: %{timezoneId: zone}
      })

    session
  end

  defp browser_zone(session) do
    evaluate_script(session, "return Intl.DateTimeFormat().resolvedOptions().timeZone;")
  end

  # Shows `date`'s times: once the month grid has drawn its days, moves a
  # month on if the date is not in the month on screen (the page lands on the
  # first free day, which may be in the month before), then clicks the date
  # and waits for it to be the chosen one. The month on screen is read at
  # once, its days having drawn: `has?/2` would wait out Wallaby's whole
  # timeout before saying the date is not there.
  defp open_day(session, date) do
    day = "[data-fact='date'][data-value='#{date}']:not([data-alternate])"
    session = assert_has(session, css("[data-fact='date']:not([data-alternate])", minimum: 1))

    on_screen? =
      evaluate_script(session, "return document.querySelector(#{Jason.encode!(day)}) !== null;")

    session =
      if on_screen?,
        do: session,
        else: click(session, css("[data-intent='later']:not([data-alternate])"))

    session
    |> click(css("#{day}:not([disabled])"))
    |> assert_has(css("#{day}[aria-pressed='true']"))
    |> assert_has(css("[data-fact='time']", minimum: 1))
  end

  # The values of the chosen day's time buttons, in the order shown.
  defp day_times(session) do
    session
    |> all(css("[data-fact='time']"))
    |> Enum.map(&Element.attr(&1, "data-value"))
  end
end
