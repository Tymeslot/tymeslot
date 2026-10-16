defmodule TymeslotWeb.Live.Themes.FolioJourneyTest do
  @moduledoc """
  Folio's booking page as one continuous page (`Navigators.Continuous`):
  the masthead, then the meeting types, then the calendar once a type is
  chosen, then the details once a time is, with the summary bar of what is
  chosen; the confirmation below the masthead; a meeting type's own link
  showing that type alone.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @theme_id "4"

  @company %{
    "id" => "cf-company",
    "type" => "short_text",
    "label" => "Company",
    "required" => true,
    "position" => 0
  }

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  defp ahead, do: Date.utc_today() |> Date.add(3) |> Date.to_iso8601()

  test "opens on the masthead and the meeting types, nothing below them yet", %{conn: conn} do
    %{profile: profile} = seed_organiser(@theme_id, "folio-open")
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    assert has_element?(view, ".journey--continuous #masthead-step .folio-masthead--full")
    assert has_element?(view, "#offer-step [data-fact='meeting_type'][data-value='quick-chat']")
    refute has_element?(view, "#when-step")
    refute has_element?(view, "[data-testid='summary-bar']")
    refute has_element?(view, "[data-testid='next-step']")
  end

  test "a chosen type opens the calendar below and the summary bar above", %{conn: conn} do
    %{profile: profile} = seed_organiser(@theme_id, "folio-choose")
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    BookingDriver.choose_meeting_type(view, "quick-chat")
    assert_patch(view, "/#{profile.username}/quick-chat")

    assert has_element?(view, "#offer-step[data-moment-state='done']")
    assert has_element?(view, "#when-step [data-fact='date']")
    assert has_element?(view, "#when-step h2", "When suits you?")

    # The stylesheet marks the chosen type by this attribute.
    assert has_element?(
             view,
             "#offer-step [data-fact='meeting_type'][data-value='quick-chat'][aria-current='true']"
           )

    assert has_element?(
             view,
             "#masthead-step [data-testid='summary-bar-meeting-type']",
             "Quick Chat"
           )

    refute has_element?(view, "#you-step")
  end

  @tag :capture_log
  test "a picked time opens the details, and the booking ends below the masthead",
       %{conn: conn} do
    %{user: user, profile: profile} = seed_organiser(@theme_id, "folio-book")
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    BookingDriver.choose_meeting_type(view, "quick-chat")
    assert_patch(view, "/#{profile.username}/quick-chat")
    {day, _time} = BookingDriver.pick_first_slot(view, on: ahead())
    assert_patch(view, "/#{profile.username}/quick-chat/book")

    assert has_element?(view, "#you-step form[data-fact='attendee']")
    assert has_element?(view, "#you-step h2", "A little about you")
    assert has_element?(view, "[data-testid='summary-bar-slot']")

    BookingDriver.submit(view, %{name: "Mia Laurent", email: "mia@example.com"})
    await(view, "[data-testid='confirmation-heading']")

    date = Date.from_iso8601!(day)
    weekday = date |> Date.day_of_week() |> LocalizationHelpers.mid_sentence_weekday()

    assert has_element?(
             view,
             "[data-testid='confirmation-heading']",
             "See you on #{weekday} #{LocalizationHelpers.format_date(date)}, Mia"
           )

    assert has_element?(view, "[data-testid='schedule-another']", "Book another session")

    assert has_element?(view, ".folio-masthead--full")
    refute has_element?(view, "#offer-step")

    meeting =
      Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: "mia@example.com")

    assert Date.to_iso8601(DateTime.to_date(meeting.start_time)) == day
  end

  @tag :capture_log
  test "asks the meeting type's questions in the details before the form", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_organiser(@theme_id, "folio-questions",
        types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: [@company]]]
      )

    {:ok, view, _html} = live(conn, "/#{profile.username}")
    BookingDriver.choose_meeting_type(view, "quick-chat")
    BookingDriver.pick_first_slot(view, on: ahead())

    assert has_element?(view, "#you-step [data-fact='answer'][data-question='cf-company']")
    refute has_element?(view, "form[data-fact='attendee']")

    BookingDriver.answer(view, "cf-company", "Acme")
    BookingDriver.continue(view)

    assert has_element?(view, "#you-step form[data-fact='attendee']")

    BookingDriver.submit(view, %{name: "Mia Laurent", email: "mia-questions@example.com"})
    await(view, "[data-testid='confirmation-heading']")

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "mia-questions@example.com"
      )

    assert meeting.custom_field_answers == %{"cf-company" => "Acme"}
  end

  describe "focus when the questions close" do
    @role %{
      "id" => "cf-role",
      "type" => "short_text",
      "label" => "Role",
      "required" => true,
      "position" => 1
    }

    defp open_questions(conn, slug, fields) do
      %{profile: profile} =
        seed_organiser(@theme_id, slug,
          types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: fields]]
        )

      {:ok, view, _html} = live(conn, "/#{profile.username}")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.pick_first_slot(view, on: ahead())
      view
    end

    test "the details take the focus after the last Continue, not before", %{conn: conn} do
      view = open_questions(conn, "folio-focus-last", [@company])

      refute has_element?(view, "#folio-details")
      refute has_element?(view, "#folio-question-0[phx-mounted]")

      BookingDriver.answer(view, "cf-company", "Acme")
      BookingDriver.continue(view)

      assert has_element?(view, "#you-step #folio-details[phx-mounted*='focus']")
    end

    test "Back to the first question focuses its label, a fresh mount does not", %{conn: conn} do
      view = open_questions(conn, "folio-focus-back", [@company, @role])

      assert has_element?(view, "#folio-question-0")
      refute has_element?(view, "#folio-question-0[phx-mounted]")

      BookingDriver.answer(view, "cf-company", "Acme")
      BookingDriver.continue(view)

      assert has_element?(view, "#folio-question-1")
      refute has_element?(view, "#folio-question-1[phx-mounted]")

      BookingDriver.back(view)

      assert has_element?(view, "#folio-question-0[phx-mounted*='focus']")
    end

    test "a deep link to the details does not move the focus", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "folio-focus-deep")

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/quick-chat/book?date=#{ahead()}&time=10:00%20AM&timezone=Etc%2FUTC"
        )

      assert has_element?(view, "#folio-details")
      refute has_element?(view, "#folio-details[phx-mounted]")
    end
  end

  test "a meeting type's own link shows that type alone, with the calendar open",
       %{conn: conn} do
    %{profile: profile} =
      seed_organiser(@theme_id, "folio-link",
        types: [
          [name: "Quick Chat", duration_minutes: 30],
          [name: "Long Talk", duration_minutes: 60]
        ]
      )

    {:ok, view, _html} = live(conn, "/#{profile.username}/long-talk")

    assert has_element?(view, "#offer-step .folio-meeting--chosen", "Long Talk")
    refute has_element?(view, "[data-fact='meeting_type']")
    assert has_element?(view, "#when-step [data-fact='date']")
  end

  test "each entry names its length, where it is held and its price", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_organiser(@theme_id, "folio-facts",
        types: [
          [
            name: "Strategy Session",
            duration_minutes: 60,
            payment_required: true,
            price_cents: 12_000,
            locations: [
              %LocationOption{id: "office", kind: "in_person", label: "My studio", position: 0}
            ]
          ]
        ]
      )

    insert(:connect_account, user: user, default_currency: "chf")
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    entry = "#offer-step [data-fact='meeting_type'][data-value='strategy-session']"
    assert has_element?(view, "#{entry} .folio-meeting__duration")
    assert has_element?(view, "#{entry} [data-testid='folio-meeting-location']", "My studio")
    assert has_element?(view, "#{entry} .folio-meeting__price", "CHF 120.00")
  end

  test "the bar carries the organiser, and the masthead links down to the offers",
       %{conn: conn} do
    %{profile: profile} = seed_organiser(@theme_id, "folio-person")
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    assert has_element?(
             view,
             "#masthead-step a[href='#offer-step'][data-testid='folio-jump-to-offer']"
           )

    BookingDriver.choose_meeting_type(view, "quick-chat")

    assert has_element?(view, "[data-testid='folio-summary-bar'] .folio-summary-bar__portrait")
    assert has_element?(view, "[data-testid='folio-summary-bar'] [data-testid='summary-bar']")
    refute has_element?(view, "[data-testid='folio-jump-to-offer']")
    refute has_element?(view, "#when-step", "Duration:")
  end

  test "says there are no free times when no day in the window is free", %{conn: conn} do
    # Free on no weekday at all, so the page lands on no day.
    %{profile: profile} = seed_organiser(@theme_id, "folio-full", days: [])
    {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat")

    await_availability(view)

    assert has_element?(
             view,
             "#when-step [data-testid='folio-month-empty']",
             "I have no free times at the moment."
           )

    refute has_element?(view, "[data-testid='folio-next-free-day']")
  end

  test "says so in its own words when there are no meeting types", %{conn: conn} do
    %{profile: profile} = seed_organiser(@theme_id, "folio-none", types: [])
    {:ok, view, _html} = live(conn, "/#{profile.username}")

    assert has_element?(
             view,
             "#offer-step .folio-empty",
             "I'm not taking new bookings at the moment."
           )

    refute has_element?(view, "#offer-step", "No meeting types available")
  end
end
