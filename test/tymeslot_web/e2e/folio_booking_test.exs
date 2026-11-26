defmodule TymeslotWeb.E2E.FolioBookingTest do
  @moduledoc """
  A booking through Folio, the continuous page (`journey: :custom` on
  `Navigators.Continuous`), in a real browser, from the overview to the
  confirmation: choosing a way to work opens the calendar below it, picking a
  day and then a time opens the details below that with no Next, and the
  submit replaces everything under the masthead with the confirmation. The
  journey ends in the database, at the day and time the visitor clicked.

  The LiveView suites walk Folio through `BookingDriver`; this is the one
  place its moments open one below the other in a browser, through its own
  JavaScript (the reveal on a day's click, the focus moves) and its own
  stylesheet.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.ThemeTestMatrix
  alias Wallaby.Element

  @moduletag :e2e
  @moduletag :themes

  @email "folio-booker@example.com"
  @type_name "Folio Portfolio Review"

  feature "a visitor books through Folio's continuous page", %{session: session} do
    {profile, slug} = create_folio_host()

    session =
      session
      |> resize_window(1280, 900)
      |> visit("/#{profile.username}")
      |> wait_for_live()
      |> assert_has(css(".journey--continuous"))
      |> assert_has(css("#offer-step[data-moment-state='current']"))

    # Nothing below the ways to work until one is chosen.
    assert_absent(session, "#when-step")

    # Choosing the type opens the calendar below, with the type in the
    # masthead's summary bar.
    session =
      session
      |> click(css("[data-fact='meeting_type'][data-value='#{slug}']"))
      |> assert_has(css("#when-step[data-moment-state='current']"))
      |> assert_has(css("[data-testid='folio-summary-bar']", text: @type_name))

    {date, time, label} = pick_slot(session)

    # The details open below on their own, naming the time the visitor
    # picked; Folio has no Next anywhere on the way.
    session =
      session
      |> assert_has(css("#you-step[data-moment-state='current']"))
      |> assert_has(css("[data-testid='folio-you-when']", text: label))
      |> assert_has(css("#folio-details [data-testid='booking-form']"))

    assert_absent(session, "[data-testid='next-step']")

    session
    |> fill_in(css("input[name='booking[name]']"), with: "Folio Booker")
    |> fill_in(css("input[name='booking[email]']"), with: @email)
    |> click(css("[data-testid='submit-booking']"))
    |> assert_has(css("[data-testid='folio-confirmation'] [data-testid='confirmation-heading']"))
    |> assert_has(css("[data-testid='chosen-meeting-type']", text: @type_name))
    |> assert_absent("#when-step")

    assert_booked_at(date, time)
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  # A host on Folio with a connected calendar and one 30-minute type of its
  # own beside the seeded ones. Returns the profile and the type's slug.
  defp create_folio_host do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: @type_name,
        duration_minutes: 30,
        is_active: true
      })

    profile =
      user.id
      |> Profiles.get_profile()
      |> Changeset.change(booking_theme: folio_id())
      |> Repo.update!()

    {profile, MeetingTypes.effective_slug(meeting_type)}
  end

  defp folio_id do
    %{id: id} = Enum.find(ThemeTestMatrix.all(), &(&1.key == :folio))
    id
  end

  # ── Steps ──────────────────────────────────────────────────────────────

  # Picks the first free day and waits for it to be the chosen one, so the
  # times read next are that day's and not the landing day's, then clicks
  # its first time. Returns the day, the time the button sends, and the time
  # as the button shows it.
  defp pick_slot(session) do
    day_selector = "#when-step [data-fact='date']:not([disabled])"
    session = assert_has(session, css(day_selector, minimum: 1))

    date =
      session
      |> find(css(day_selector, count: :any))
      |> List.first()
      |> Element.attr("data-value")

    session
    |> click(css("#when-step [data-fact='date'][data-value='#{date}']"))
    |> assert_has(css("#when-step [data-fact='date'][data-value='#{date}'][aria-pressed='true']"))
    |> assert_has(css("#when-step [data-fact='time']", minimum: 1))

    slot = session |> find(css("#when-step [data-fact='time']", count: :any)) |> List.first()
    {time, label} = {Element.attr(slot, "data-value"), Element.text(slot)}
    Element.click(slot)

    {date, time, label}
  end

  # No element matches, shown or not. `refute_has/2` would wait out its full
  # timeout before passing; a count of zero returns as soon as it holds.
  defp assert_absent(session, selector),
    do: assert_has(session, css(selector, count: 0, visible: :any))

  # The meeting starts at `date` and `time` in the booker's own timezone.
  defp assert_booked_at(date, time) do
    meeting = Repo.get_by!(MeetingSchema, attendee_email: @email)
    local = DateTime.shift_zone!(meeting.start_time, meeting.attendee_timezone)

    assert {Date.to_iso8601(DateTime.to_date(local)), Calendar.strftime(local, "%-I:%M %p")} ==
             {date, time}

    assert meeting.status == :confirmed
  end
end
