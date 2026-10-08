defmodule TymeslotWeb.Live.Themes.ExpressJourneyTest do
  @moduledoc """
  Bookings through Fixture Express (`"94"`, `test/support/journey_fixtures/`),
  a time-first journey on `Navigators.Paged`: the first screen is the
  soonest free times, with the meeting type chosen by the moment's default
  and a switcher when there are several; the second asks the meeting type's
  questions, when it has some, and then for the details.
  `NextSlots` asks for its week from `phx-mounted`, which LiveViewTest does
  not run, so `load_week/2` sends it by hand.
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
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.BookingDriver.Page

  @theme_id "94"

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

  # The first free time three days ahead, so neither a slot boundary nor the
  # minimum notice can take it while the test runs.
  defp pick_ahead(view) do
    day = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
    {^day, _time} = BookingDriver.pick_first_slot(view, on: day)
  end

  defp next_week(view) do
    view |> element("#now-step [data-intent='later']") |> render_click()
    await_week(view)
  end

  defp slot_dates(view), do: Page.attribute(view, "[data-fact='slot']", "data-date")

  describe "the first screen" do
    test "is the soonest times, with the only meeting type already chosen", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "express-first")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      assert has_element?(view, ".journey-fixture-express #now-step [data-testid='next-slots']")
      refute has_element?(view, "[data-fact='meeting_type']")
      refute has_element?(view, "#you-step")
      assert live_assigns(view).selected_duration == "quick-chat"
    end

    # The week on show has free times on its last days only (a visitor on a
    # Saturday sees Saturday and Sunday); the next week must still be reached.
    test "reaches the next week's times from a week that still has free ones",
         %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "express-weekend", days: [6, 7])
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
      load_week(view, "#now-step")

      shown = slot_dates(view)

      assert shown != []
      assert Enum.all?(shown, &weekend?/1)

      next_week(view)

      later = slot_dates(view)

      assert later != []
      assert Enum.min(later) > Enum.max(shown)
      assert Enum.all?(later, &weekend?/1)
    end
  end

  describe "booking" do
    @tag :capture_log
    test "books the time picked from the first screen in two steps", %{conn: conn} do
      %{user: user, profile: profile, meeting_types: [type]} =
        seed_organiser(@theme_id, "express-book")

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      pick_ahead(view)
      BookingDriver.continue(view)

      assert has_element?(view, "#you-step")
      refute has_element?(view, "#now-step")

      BookingDriver.submit(view, %{name: "Sam Okafor", email: "sam@example.com"})
      await(view, "[data-testid='confirmation-heading']")

      meeting =
        Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: "sam@example.com")

      assert meeting.meeting_type_id == type.id
    end

    @tag :capture_log
    test "asks the meeting type's questions above the details, then books with the answers",
         %{conn: conn} do
      %{user: user, profile: profile} =
        seed_organiser(@theme_id, "express-questions",
          types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: [@company]]]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      pick_ahead(view)
      BookingDriver.continue(view)

      assert has_element?(view, "#you-step [data-fact='answer'][data-question='cf-company']")
      refute has_element?(view, "form[data-fact='attendee']")

      BookingDriver.answer(view, "cf-company", "Acme")

      # Answered but not yet confirmed: the form waits for Continue.
      refute has_element?(view, "form[data-fact='attendee']")

      BookingDriver.continue(view)

      assert has_element?(view, "#you-step form[data-fact='attendee']")
      refute has_element?(view, "[data-fact='answer']")

      BookingDriver.submit(view, %{name: "Sam Okafor", email: "sam-questions@example.com"})
      await(view, "[data-testid='confirmation-heading']")

      meeting =
        Repo.get_by!(MeetingSchema,
          organizer_user_id: user.id,
          attendee_email: "sam-questions@example.com"
        )

      assert meeting.custom_field_answers == %{"cf-company" => "Acme"}
    end
  end

  describe "the meeting type switcher" do
    test "shows with several types and refreshes the times for the one chosen", %{conn: conn} do
      %{profile: profile} =
        seed_organiser(@theme_id, "express-switch",
          types: [
            [name: "Quick Chat", duration_minutes: 30],
            [name: "Long Talk", duration_minutes: 60]
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
      load_week(view, "#now-step")

      # The next week is wholly ahead, so its days keep every time whatever
      # the hour the suite runs.
      next_week(view)

      assert has_element?(
               view,
               "[data-fact='meeting_type'][data-value='quick-chat'][aria-pressed='true']"
             )

      assert "4:30 PM" in slot_times(view)

      BookingDriver.choose_meeting_type(view, "long-talk")
      await_week(view)

      times = slot_times(view)
      assert "4:00 PM" in times
      refute "4:30 PM" in times
    end
  end

  describe "a meeting type's own link" do
    test "names its type alone, with no switcher to the others", %{conn: conn} do
      %{profile: profile} =
        seed_organiser(@theme_id, "express-direct",
          types: [
            [name: "Quick Chat", duration_minutes: 30],
            [name: "Long Talk", duration_minutes: 60]
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}/long-talk")

      refute has_element?(view, "[data-fact='meeting_type']")
      refute render(view) =~ "Quick Chat"
      assert has_element?(view, "#now-step [data-testid='journey-fixture-answer']", "Long Talk")
      assert live_assigns(view).meeting_type.name == "Long Talk"
    end

    test "keeps its type against a crafted choice of another", %{conn: conn} do
      %{profile: profile} =
        seed_organiser(@theme_id, "express-direct-push",
          types: [
            [name: "Quick Chat", duration_minutes: 30],
            [name: "Long Talk", duration_minutes: 60]
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}/long-talk")

      push_duration(view, "quick-chat")

      assert live_assigns(view).meeting_type.name == "Long Talk"
      assert live_assigns(view).selected_duration == "long-talk"
    end

    test "of a private type keeps it against a crafted choice of another private one",
         %{conn: conn} do
      %{profile: profile, meeting_types: [_public, secret, hidden]} =
        seed_organiser(@theme_id, "express-private-push",
          types: [
            [name: "Quick Chat", duration_minutes: 30],
            [name: "Secret", is_private: true],
            [name: "Hidden", is_private: true]
          ]
        )

      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}/#{MeetingTypes.effective_slug(secret)}")

      assert live_assigns(view).meeting_type.id == secret.id

      push_duration(view, MeetingTypes.effective_slug(hidden))

      assert live_assigns(view).meeting_type.id == secret.id
    end
  end

  describe "the profile page" do
    test "still takes another type sent from the first screen", %{conn: conn} do
      %{profile: profile} =
        seed_organiser(@theme_id, "express-overview-push",
          types: [
            [name: "Quick Chat", duration_minutes: 30],
            [name: "Long Talk", duration_minutes: 60]
          ]
        )

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      push_duration(view, "long-talk")

      assert live_assigns(view).meeting_type.name == "Long Talk"
    end
  end

  # A `select_duration` push as a crafted client would send it, whether or
  # not the moment renders a control for it.
  defp push_duration(view, slug) do
    view |> with_target("#now-step") |> render_click("select_duration", %{"duration" => slug})
  end

  defp weekend?(iso), do: iso |> Date.from_iso8601!() |> Date.day_of_week() >= 6
end
