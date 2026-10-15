defmodule TymeslotWeb.Live.Themes.TwoJourneyTest do
  @moduledoc """
  Bookings through Fixture Two (`"93"`, `test/support/journey_fixtures/`), a
  paged journey of two screens: the meeting types, then one moment that
  collects the slot, the answers and the attendee. The attendee's entry (the
  form and its submission token) waits on that screen until a time is
  picked; it never redirects. The meeting type's questions sit above the
  form, all at once, and one submit sends both: the submission validates
  the answers and names each question that fails.
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
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.BookingDriver.Page

  @theme_id "93"

  @company %{
    "id" => "cf-company",
    "type" => "short_text",
    "label" => "Company",
    "required" => true,
    "position" => 0
  }

  @team %{
    "id" => "cf-team",
    "type" => "short_text",
    "label" => "Team",
    "required" => false,
    "position" => 1
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

  defp open_second_screen(conn, profile) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.choose_meeting_type(view, "quick-chat")
    BookingDriver.continue(view)
    view
  end

  defp with_questions(name, questions),
    do:
      seed_organiser(@theme_id, name,
        types: [[name: "Quick Chat", duration_minutes: 30, custom_fields: questions]]
      )

  defp form?(view), do: has_element?(view, "#pick-step form[data-fact='attendee']")

  defp question?(view, id),
    do: has_element?(view, "#pick-step [data-fact='answer'][data-question='#{id}']")

  describe "the second screen" do
    test "opens on its picker, with no details and no submission token yet", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "two-open")
      view = open_second_screen(conn, profile)

      assert has_element?(view, "#pick-step [data-fact='date']")
      refute has_element?(view, "#offer-step")
      refute form?(view)
      assert live_assigns(view).submission_token == nil
    end

    test "opens straight from a meeting type's own link, with no redirect", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "two-link")
      {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat?timezone=Etc/UTC")

      assert has_element?(view, "#pick-step [data-fact='date']")
      refute form?(view)
    end

    test "shows the details, with a submission token, once a time is picked", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "two-details")
      view = open_second_screen(conn, profile)

      BookingDriver.pick_first_slot(view, on: ahead())

      assert form?(view)
      assert byte_size(live_assigns(view).submission_token) > 0
    end

    test "shows every question above the details once a time is picked, with no way on",
         %{conn: conn} do
      %{profile: profile} = with_questions("two-all", [@company, @team])
      view = open_second_screen(conn, profile)

      refute question?(view, "cf-company")

      BookingDriver.pick_first_slot(view, on: ahead())

      assert question?(view, "cf-company")
      assert question?(view, "cf-team")
      assert form?(view)
      refute has_element?(view, "#pick-step [data-intent='continue']")
    end

    test "Back returns to the meeting types", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "two-back")
      view = open_second_screen(conn, profile)

      BookingDriver.back(view)

      assert has_element?(view, "#offer-step [data-fact='meeting_type']")
      refute has_element?(view, "#pick-step")
    end

    test "Enter in a question's field steps nothing: Back still returns to the meeting types",
         %{conn: conn} do
      %{profile: profile} = with_questions("two-enter", [@company, @team])
      view = open_second_screen(conn, profile)
      BookingDriver.pick_first_slot(view, on: ahead())

      view
      |> form("#pick-step form[data-fact='answer'][data-question='cf-company']", %{
        "value" => "Acme"
      })
      |> render_submit()

      assert question?(view, "cf-team")
      assert live_assigns(view).engine.current_index == 0

      BookingDriver.back(view)

      assert has_element?(view, "#offer-step [data-fact='meeting_type']")
    end
  end

  describe "booking" do
    @tag :capture_log
    test "books the time picked on the second screen", %{conn: conn} do
      %{user: user, profile: profile} = seed_organiser(@theme_id, "two-book")
      view = open_second_screen(conn, profile)

      {day, time} = BookingDriver.pick_first_slot(view, on: ahead())
      BookingDriver.submit(view, %{name: "Ana Silva", email: "ana@example.com"})
      await(view, "[data-testid='confirmation-heading']")

      meeting =
        Repo.get_by!(MeetingSchema, organizer_user_id: user.id, attendee_email: "ana@example.com")

      {:ok, clock} = DateTimeUtils.parse_time_string(time)
      assert Date.to_iso8601(DateTime.to_date(meeting.start_time)) == day
      assert Time.compare(DateTime.to_time(meeting.start_time), clock) == :eq
    end

    @tag :capture_log
    test "keeps the details when the time changes, and books the new time", %{conn: conn} do
      %{user: user, profile: profile} = seed_organiser(@theme_id, "two-change")
      view = open_second_screen(conn, profile)

      {day, first} = BookingDriver.pick_first_slot(view, on: ahead())
      token = live_assigns(view).submission_token
      [second | _rest] = Page.attribute(view, "[data-fact='time']", "data-value") -- [first]
      BookingDriver.pick_time(view, second)

      assert form?(view)
      assert live_assigns(view).submission_token == token

      BookingDriver.submit(view, %{name: "Ana Silva", email: "ana-change@example.com"})
      await(view, "[data-testid='confirmation-heading']")

      meeting =
        Repo.get_by!(MeetingSchema,
          organizer_user_id: user.id,
          attendee_email: "ana-change@example.com"
        )

      {:ok, clock} = DateTimeUtils.parse_time_string(second)
      assert Date.to_iso8601(DateTime.to_date(meeting.start_time)) == day
      assert Time.compare(DateTime.to_time(meeting.start_time), clock) == :eq
    end

    @tag :capture_log
    test "books the answers given above the details with the one submit", %{conn: conn} do
      %{user: user, profile: profile} = with_questions("two-questions", [@company, @team])
      view = open_second_screen(conn, profile)
      BookingDriver.pick_first_slot(view, on: ahead())

      # The second question first: each answer names its own question.
      BookingDriver.answer(view, "cf-team", "Design")
      BookingDriver.answer(view, "cf-company", "Acme")

      BookingDriver.submit(view, %{name: "Ana Silva", email: "ana-questions@example.com"})
      await(view, "[data-testid='confirmation-heading']")

      meeting =
        Repo.get_by!(MeetingSchema,
          organizer_user_id: user.id,
          attendee_email: "ana-questions@example.com"
        )

      assert meeting.custom_field_answers == %{"cf-company" => "Acme", "cf-team" => "Design"}
    end

    @tag :capture_log
    test "a submit with a required question unanswered names it and books nothing",
         %{conn: conn} do
      %{user: user, profile: profile} = with_questions("two-missing", [@company, @team])
      view = open_second_screen(conn, profile)
      BookingDriver.pick_first_slot(view, on: ahead())

      BookingDriver.submit(view, %{name: "Ana Silva", email: "ana-missing@example.com"})

      assert has_element?(
               view,
               "[data-testid='journey-fixture-question']:has([data-question='cf-company']) " <>
                 "[data-testid='journey-fixture-question-error']"
             )

      refute has_element?(
               view,
               "[data-testid='journey-fixture-question']:has([data-question='cf-team']) " <>
                 "[data-testid='journey-fixture-question-error']"
             )

      assert form?(view)

      refute Repo.get_by(MeetingSchema,
               organizer_user_id: user.id,
               attendee_email: "ana-missing@example.com"
             )

      BookingDriver.answer(view, "cf-company", "Acme")

      refute has_element?(view, "[data-testid='journey-fixture-question-error']")
    end

    @tag :capture_log
    test "a refused question shows beside the form's own errors, and keeps its error as the visitor types",
         %{conn: conn} do
      %{profile: profile} = with_questions("two-both", [@company, @team])
      view = open_second_screen(conn, profile)
      BookingDriver.pick_first_slot(view, on: ahead())

      view
      |> form("#pick-step form[data-fact='attendee']", %{
        "booking" => %{"name" => "Ana Silva", "email" => ""}
      })
      |> render_submit()

      assert has_element?(view, "[data-testid='journey-fixture-question-error']")
      # The form's own error (the blank email) shows too: both at once.
      assert has_element?(view, "#pick-step form[data-fact='attendee'] .form-field-error")

      BookingDriver.fill_attendee(view, %{name: "Ana Silva", email: "ana-both@example.com"})

      assert has_element?(view, "[data-testid='journey-fixture-question-error']")
    end

    test "a link to the booking with a day and a time opens with the details",
         %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "two-deep")

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/quick-chat/book?date=#{ahead()}&time=10:00%20AM&timezone=Etc/UTC"
        )

      assert form?(view)
    end
  end
end
