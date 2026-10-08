defmodule TymeslotWeb.Live.Themes.TalkJourneyTest do
  @moduledoc """
  Bookings through Fixture Talk (`"95"`, `test/support/journey_fixtures/`),
  a conversation on `Navigators.Transcript`: the answered moments stay above
  as a list, the current one is last, an organiser's only meeting type is
  chosen for the visitor by the opening moment's default, and Edit forgets an
  answer and every answer depending on it.
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

  @theme_id "95"

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

  defp open_talk(conn, username, opts \\ []) do
    %{user: user, profile: profile} = seed_organiser(@theme_id, username, opts)
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
    %{view: view, user: user}
  end

  # The conversation up to the attendee moment, on a day a few ahead, so
  # neither a slot boundary nor the minimum notice can take the time while
  # the test runs. Returns the day.
  defp answer_time(view) do
    day = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
    {^day, _time} = BookingDriver.pick_first_slot(view, on: day)
    assert state(view, :you) == "current"
    day
  end

  describe "the opening" do
    test "chooses an organiser's only meeting type and starts at the day", %{conn: conn} do
      %{view: view} = open_talk(conn, "talk-default")

      assert state(view, :hello) == "done"

      assert has_element?(
               view,
               "#hello-step [data-testid='journey-fixture-answer']",
               "Quick Chat"
             )

      assert state(view, :day) == "open"
      assert state(view, :time) == "current"
      refute has_element?(view, "#you-step")
    end

    test "is an ordered list that announces what is added to it", %{conn: conn} do
      %{view: view} = open_talk(conn, "talk-list")

      assert has_element?(
               view,
               ".journey-fixture-talk ol.journey--transcript[aria-live='polite'] > li#hello-step"
             )

      assert has_element?(view, "ol.journey--transcript > li#time-step")
    end

    test "leaves the choice to the visitor when the organiser offers several types",
         %{conn: conn} do
      %{view: view} =
        open_talk(conn, "talk-several",
          types: [
            [name: "Quick Chat", duration_minutes: 30],
            [name: "Long Talk", duration_minutes: 60]
          ]
        )

      assert state(view, :hello) == "current"
      assert BookingDriver.meeting_types(view) == ["quick-chat", "long-talk"]
      refute has_element?(view, "#day-step")

      BookingDriver.choose_meeting_type(view, "long-talk")

      assert state(view, :hello) == "done"
      assert state(view, :time) == "current"
    end
  end

  describe "the questions" do
    test "are asked after the meeting type and before the day", %{conn: conn} do
      %{view: view} =
        open_talk(conn, "talk-questions",
          types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: [@company]]]
        )

      assert state(view, :hello) == "done"
      assert state(view, :ask) == "current"
      assert has_element?(view, "li#ask-step [data-fact='answer'][data-question='cf-company']")
      refute has_element?(view, "#day-step")

      BookingDriver.answer(view, "cf-company", "Acme")
      BookingDriver.continue(view)

      assert state(view, :ask) == "done"
      assert has_element?(view, "#ask-step [data-intent='edit']")
      assert state(view, :day) == "open"
      assert state(view, :time) == "current"
    end
  end

  describe "the day" do
    test "offers the free days as chips, and once a time is chosen names the day",
         %{conn: conn} do
      %{view: view} = open_talk(conn, "talk-day")

      assert has_element?(view, "#day-step [data-fact='date']")

      day = answer_time(view)

      refute has_element?(view, "#day-step [data-fact='date']")
      assert live_assigns(view).selected_date == day
      assert has_element?(view, "#day-step [data-testid='journey-fixture-day']")
    end
  end

  describe "Edit" do
    test "on the time forgets it and closes the attendee moment, keeping the day", %{conn: conn} do
      %{view: view} = open_talk(conn, "talk-edit-time")
      day = answer_time(view)

      assert byte_size(live_assigns(view).submission_token) > 0

      BookingDriver.edit(view, :time)

      assert state(view, :time) == "current"
      refute has_element?(view, "#you-step")
      assert live_assigns(view).selected_time == nil
      assert live_assigns(view).selected_date == day
      assert live_assigns(view).submission_token == nil
      assert has_element?(view, "#time-heading-current[phx-mounted*='focus']")
    end

    test "on the meeting type forgets every answer after it", %{conn: conn} do
      %{view: view} = open_talk(conn, "talk-edit-type")
      answer_time(view)

      BookingDriver.edit(view, :hello)

      assert state(view, :hello) == "current"
      refute has_element?(view, "#day-step")
      refute has_element?(view, "#time-step")
      refute has_element?(view, "#you-step")
      assert live_assigns(view).selected_duration == nil
      assert live_assigns(view).selected_time == nil

      # Answering again opens the rest of the conversation again.
      BookingDriver.choose_meeting_type(view, "quick-chat")

      assert state(view, :hello) == "done"
      assert state(view, :time) == "current"
    end

    test "is offered only on answered moments", %{conn: conn} do
      %{view: view} = open_talk(conn, "talk-edit-offer")

      assert has_element?(view, "#hello-step [data-intent='edit']")
      refute has_element?(view, "#ask-step")
      refute has_element?(view, "#time-step [data-intent='edit']")
      refute has_element?(view, "#day-step [data-intent='edit']")
    end
  end

  describe "booking" do
    @tag :capture_log
    test "books the time answered in the conversation", %{conn: conn} do
      %{view: view, user: user} = open_talk(conn, "talk-book")
      answer_time(view)

      BookingDriver.submit(view, %{name: "Noor Haddad", email: "noor@example.com"})
      await(view, "[data-testid='confirmation-heading']")

      assert Repo.get_by(MeetingSchema,
               organizer_user_id: user.id,
               attendee_email: "noor@example.com"
             )
    end
  end
end
