defmodule TymeslotWeb.Live.Themes.ScrollJourneyTest do
  @moduledoc """
  Bookings through Fixture Scroll (`"96"`, `test/support/journey_fixtures/`),
  a journey on `Navigators.Continuous` that asks a meeting type's questions
  before it shows the calendar. Driven through the markup contract
  (`TymeslotWeb.BookingDriver`), asserted on the moments' states
  (`data-moment-state`) and on the meetings stored.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @theme_id "96"

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

  defp state(view, moment), do: first_value(view, "##{moment}-step", "data-moment-state")

  describe "the page" do
    test "keeps its moments on one page in the navigator's frame", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-frame")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      assert has_element?(view, ".journey-fixture-scroll div.journey--continuous > #intro-step")
      assert state(view, :intro) == "open"
      assert state(view, :offer) == "current"
      refute has_element?(view, "#when-step")
    end
  end

  describe "a meeting type without questions" do
    test "opens the calendar straight after the meeting type", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-no-questions")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      BookingDriver.choose_meeting_type(view, "quick-chat")

      refute has_element?(view, "#ask-step")
      assert state(view, :when) == "current"

      # Opened, not merely shown: the calendar lands on the first free day
      # and that day's times come up.
      assert await_first_time(view) =~ ~r/\d/

      # A page that opens its moments by itself keeps the language switcher
      # past its first moment.
      assert has_element?(view, ".journey-fixture-language.visible")
    end
  end

  describe "a meeting type with questions" do
    @tag :capture_log
    test "asks them before it shows the calendar, and books with the answers", %{conn: conn} do
      %{user: user, profile: profile} =
        seed_organiser(@theme_id, "scroll-questions",
          types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: [@company]]]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      BookingDriver.choose_meeting_type(view, "quick-chat")

      assert state(view, :offer) == "done"
      assert state(view, :ask) == "current"
      refute has_element?(view, "#when-step")

      BookingDriver.answer(view, "cf-company", "Acme")
      BookingDriver.continue(view)

      assert state(view, :ask) == "done"
      assert state(view, :when) == "current"
      refute has_element?(view, "#you-step")

      BookingDriver.pick_time(view, await_first_time(view))

      assert state(view, :offer) == "done"
      assert state(view, :when) == "done"
      assert state(view, :you) == "current"

      BookingDriver.submit(view, %{name: "Ada Lovelace", email: "ada@example.com"})
      await(view, "[data-testid='confirmation-heading']")

      meeting =
        Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: "ada@example.com")

      assert meeting.custom_field_answers == %{"cf-company" => "Acme"}
    end
  end

  describe "the questions moment" do
    @role %{
      "id" => "cf-role",
      "type" => "short_text",
      "label" => "Role",
      "required" => false,
      "position" => 1
    }

    @topics %{
      "id" => "cf-topics",
      "type" => "multi_select",
      "label" => "Topics",
      "required" => true,
      "position" => 0,
      "options" => [
        %{"key" => "design", "label" => "Design"},
        %{"key" => "pricing", "label" => "Pricing"}
      ]
    }

    defp ask_page(conn, username, questions) do
      %{profile: profile} =
        seed_organiser(@theme_id, username,
          types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: questions]]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      view
    end

    test "shows an optional question after a required one, and stays current until Continue",
         %{conn: conn} do
      view = ask_page(conn, "scroll-ask-optional", [@company, @role])

      BookingDriver.answer(view, "cf-company", "Acme")

      assert state(view, :ask) == "current"
      refute has_element?(view, "#when-step")

      BookingDriver.continue(view)

      assert state(view, :ask) == "current"
      assert has_element?(view, "#ask-step [data-fact='answer'][data-question='cf-role']")
      refute has_element?(view, "#when-step")

      BookingDriver.continue(view)

      assert state(view, :ask) == "done"
      assert state(view, :when) == "current"
    end

    test "keeps a multiple choice open after its first choice", %{conn: conn} do
      view = ask_page(conn, "scroll-ask-multi", [@topics])

      BookingDriver.answer(view, "cf-topics", ["design"])

      assert state(view, :ask) == "current"
      assert has_element?(view, "#ask-step [data-question='cf-topics'][data-value='pricing']")

      BookingDriver.answer(view, "cf-topics", ["pricing"])
      BookingDriver.continue(view)

      assert state(view, :ask) == "done"

      assert Enum.sort(live_assigns(view).engine.answers["cf-topics"]) == ["design", "pricing"]
    end

    test "keeps the focus on the question while it is answered", %{conn: conn} do
      view = ask_page(conn, "scroll-ask-focus", [@company, @role])

      assert has_element?(view, "#ask-heading-current[phx-mounted*='focus']")

      BookingDriver.answer(view, "cf-company", "Acme")

      assert has_element?(view, "#ask-heading-current[phx-mounted*='focus']")
      refute has_element?(view, "#when-step")
    end

    test "once confirmed says so and offers no question", %{conn: conn} do
      view = ask_page(conn, "scroll-ask-done", [@company])

      BookingDriver.answer(view, "cf-company", "Acme")
      BookingDriver.continue(view)

      assert has_element?(view, "#ask-step [data-testid='journey-fixture-answers']")
      refute has_element?(view, "#ask-step [data-fact='answer']")
    end
  end

  describe "Book another" do
    @tag :capture_log
    test "keeps the meeting type and asks the rest again", %{conn: conn} do
      %{profile: profile} =
        seed_organiser(@theme_id, "scroll-again",
          types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: [@company]]]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      BookingDriver.book(view, answers: %{"cf-company" => "Acme"})
      BookingDriver.restart(view)
      BookingDriver.choose_meeting_type(view, "quick-chat")

      assert state(view, :ask) == "current"
      assert has_element?(view, "#ask-step form[data-fact='answer'][data-question='cf-company']")
      refute render(view) =~ "Acme"

      BookingDriver.answer(view, "cf-company", "Initech")
      BookingDriver.continue(view)
      BookingDriver.pick_time(view, await_first_time(view))

      assert state(view, :you) == "current"
      assert has_element?(view, "#you-heading-current[phx-mounted*='focus']")
    end
  end

  describe "the submission token" do
    test "is created when the attendee moment opens, and again when it opens again",
         %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-token")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      BookingDriver.choose_meeting_type(view, "quick-chat")
      time = await_first_time(view)

      assert live_assigns(view).submission_token == nil

      BookingDriver.pick_time(view, time)
      first = live_assigns(view).submission_token

      assert byte_size(first) > 0

      # Another day forgets the time, so the attendee moment closes; a time on
      # that day opens it again.
      BookingDriver.pick_date(view, another_free_date(view, live_assigns(view).selected_date))

      refute has_element?(view, "#you-step")
      assert state(view, :when) == "current"

      BookingDriver.pick_time(view, await_first_time(view))
      second = live_assigns(view).submission_token

      assert byte_size(second) > 0
      assert second != first
    end
  end

  describe "the summary bar" do
    test "follows the choices and links each back to the moment that took it", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-summary")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      refute has_element?(view, "[data-testid='summary-bar']")

      BookingDriver.choose_meeting_type(view, "quick-chat")

      assert has_element?(
               view,
               "#intro-step a[data-testid='summary-bar-meeting-type'][href='#offer-step']",
               "Quick Chat"
             )

      refute has_element?(view, "[data-testid='summary-bar-slot']")

      BookingDriver.pick_time(view, await_first_time(view))

      assert has_element?(
               view,
               "#intro-step a[data-testid='summary-bar-slot'][href='#when-step']"
             )
    end
  end

  describe "the focus" do
    test "moves to a moment that opens, and stays put on page load", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-focus")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      refute has_element?(view, "[phx-mounted*='focus']")

      BookingDriver.choose_meeting_type(view, "quick-chat")

      assert has_element?(view, "#when-heading-current[phx-mounted*='focus']")
      refute has_element?(view, "#offer-heading-done[phx-mounted*='focus']")
    end
  end

  describe "the month calendar's week start" do
    test "starts the weeks on the visitor's first day, Sunday or Monday", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-week-start")

      for {accept_language, first_heading, first_weekday} <- [
            {"en-US,en;q=0.9", "Sun", 7},
            {"en-GB,en;q=0.9", "Mon", 1}
          ] do
        {:ok, view, _html} =
          conn
          |> put_req_header("accept-language", accept_language)
          |> live(~p"/#{profile.username}")

        BookingDriver.choose_meeting_type(view, "quick-chat")
        doc = view |> render() |> Floki.parse_document!()

        assert [^first_heading | _rest] =
                 doc
                 |> Floki.find(".month-calendar__weekday")
                 |> Enum.map(&String.trim(Floki.text(&1)))

        [first_day | _rest] = Floki.attribute(doc, ".month-calendar__day", "phx-value-date")
        assert Date.day_of_week(Date.from_iso8601!(first_day)) == first_weekday
      end
    end
  end
end
