defmodule TymeslotWeb.Live.Scheduling.CustomFieldsBookingFlowTest do
  @moduledoc """
  End-to-end integration test for the custom fields booking flow on the
  Quill theme.

  Two scenarios:

  1. Booker walks the full wizard with a `short_text` and a `note` field.
     Verifies: Questions step renders, required-field validation blocks
     advancement, `note` acknowledgement is enforced, the booking is
     persisted with `custom_fields_snapshot` and `custom_field_answers`,
     and the confirmation page shows the answers.

  2. Meeting type with no custom fields uses the 4-step flow (no
     Questions step).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live
  @moduletag :custom_fields

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "cf-booker",
        booking_theme: "1",
        timezone: "America/New_York",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, user: user}
  end

  describe "booking flow with custom fields" do
    setup %{user: user} do
      base_mt =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Custom Fields Chat",
          is_active: true
        )

      {:ok, mt} =
        MeetingTypes.update_meeting_type(base_mt, %{
          "custom_fields" => [
            %{
              "id" => "cf-text-001",
              "type" => "short_text",
              "label" => "Company",
              "required" => true,
              "position" => 0
            },
            %{
              "id" => "cf-note-002",
              "type" => "note",
              "label" => "Terms",
              "body" => "Please agree to the call recording terms.",
              "required" => true,
              "position" => 1
            }
          ]
        })

      %{meeting_type: mt}
    end

    @tag :capture_log
    test "questions step renders, validation blocks advance, booking persists snapshot and answers",
         %{conn: conn, profile: profile, meeting_type: _meeting_type} do
      # Navigate overview → schedule → pick a slot (lands on :questions).
      view = navigate_to_booking_form_with_questions(conn, profile)

      # --- Questions step rendered ---
      html = render(view)
      assert html =~ "Question 1 of 2"
      assert html =~ "Company"

      # --- Required field blocks advance when empty ---
      view |> element("button[phx-click='next'][phx-target]") |> render_click()
      assert render(view) =~ "Question 1 of 2"

      # --- Fill the short_text field and advance ---
      view
      |> form("form[phx-submit='next']", %{"value" => "Acme Corp"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      assert render(view) =~ "Question 2 of 2"
      assert render(view) =~ "Please agree to the call recording terms."

      # --- Note acknowledgement is enforced ---
      view |> element("button[phx-click='next'][phx-target]") |> render_click()
      assert render(view) =~ "Question 2 of 2"

      # --- Tick acknowledgement then advance to booking ---
      view
      |> element("input[type='checkbox'][phx-value-value='acknowledge']")
      |> render_click()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      # --- Booking step ---
      assert render(view) =~ "Enter Your Details"

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Jane Doe",
          "email" => "jane.cf@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      # Drain async state
      _drain = :sys.get_state(view.pid)

      # --- Confirmation page shows answers ---
      html = render(view)
      assert html =~ "Your answers"
      assert html =~ "Company"
      assert html =~ "Acme Corp"
      assert html =~ "Terms"

      # --- Persisted booking carries snapshot and answers ---
      [meeting] = MeetingListQueries.list_meetings_by_attendee_email("jane.cf@example.com")

      # --- Confirmation offers an "Add to calendar" download for this meeting ---
      assert html =~ "Add to calendar"
      assert html =~ ~s(href="/#{profile.username}/meeting/#{meeting.uid}/calendar.ics")

      assert length(meeting.custom_fields_snapshot) == 2

      labels = Enum.map(meeting.custom_fields_snapshot, & &1["label"])
      assert "Company" in labels
      assert "Terms" in labels

      answers = meeting.custom_field_answers
      assert map_size(answers) == 2

      # The short_text answer must be the value we typed.
      text_answer =
        Enum.find_value(meeting.custom_fields_snapshot, fn d ->
          if d["label"] == "Company", do: answers[d["id"]]
        end)

      assert text_answer == "Acme Corp"

      # The note answer must record confirmation.
      note_answer =
        Enum.find_value(meeting.custom_fields_snapshot, fn d ->
          if d["label"] == "Terms", do: answers[d["id"]]
        end)

      assert match?(%{"confirmed" => true}, note_answer)
    end
  end

  describe "questions step – back-navigation preserves answers" do
    setup %{user: user} do
      base_mt =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Preserve Answers Chat",
          is_active: true
        )

      {:ok, mt} =
        MeetingTypes.update_meeting_type(base_mt, %{
          "custom_fields" => [
            %{
              "id" => "cf-preserve-001",
              "type" => "short_text",
              "label" => "Company",
              "required" => true,
              "position" => 0
            }
          ]
        })

      %{meeting_type: mt}
    end

    @tag :capture_log
    test "navigating :booking → :questions keeps previously entered answers",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form_with_questions(conn, profile)

      # Fill in the answer and advance to :booking.
      view
      |> form("form[phx-submit='next']", %{"value" => "Acme Corp"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      assert render(view) =~ "Enter Your Details"

      # Go back to :questions.
      view |> element("button[data-testid='back-step']") |> render_click()

      html = render(view)

      # The questions step re-rendered (the question label is visible).
      assert html =~ "Company"

      # The previously entered answer is still present in the input — not wiped.
      assert html =~ "Acme Corp"

      # The booking details form is gone.
      refute html =~ "Enter Your Details"
    end

    @tag :capture_log
    test "pressing back on the first question returns to the schedule step",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form_with_questions(conn, profile)

      # We're on the first (and only) question — the back button must work,
      # taking the booker back to time-slot selection rather than being a
      # dead-end.
      assert render(view) =~ "Company"

      view |> element("button[phx-click='back'][phx-target]") |> render_click()

      html = render(view)

      refute html =~ "Company"
      assert has_element?(view, "button.time-slot-button")
      assert has_element?(view, "button[phx-click='next_step']")
    end
  end

  describe "submission rejects when custom-field answers are missing at booking time" do
    setup %{user: user} do
      base_mt =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Validate Answers Chat",
          is_active: true
        )

      {:ok, mt} =
        MeetingTypes.update_meeting_type(base_mt, %{
          "custom_fields" => [
            %{
              "id" => "cf-text-001",
              "type" => "short_text",
              "label" => "Company",
              "required" => true,
              "position" => 0
            }
          ]
        })

      %{meeting_type: mt}
    end

    @tag :capture_log
    test "blank required answer in engine state stops booking creation and surfaces an error",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form_with_questions(conn, profile)

      # Walk through the wizard normally, supplying a valid answer.
      view
      |> form("form[phx-submit='next']", %{"value" => "Acme Corp"})
      |> render_change()

      view |> element("button[phx-click='next'][phx-target]") |> render_click()

      assert render(view) =~ "Enter Your Details"

      # Now wipe the answer from engine state (simulates tampered params /
      # corrupted client state reaching the submit handler). The parent
      # LiveView's `:step_event` info handler stores the new value without
      # re-validating, so the engine.answers map ends up missing the
      # required field by the time validate_and_submit runs.
      send(view.pid, {:step_event, :questions, :answer, {"cf-text-001", ""}})
      _drain = :sys.get_state(view.pid)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Mallory",
          "email" => "mallory@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      # No booking was created — the error branch short-circuited before
      # `Bookings.Create.execute/3`.
      assert MeetingListQueries.list_meetings_by_attendee_email("mallory@example.com") == []

      html = render(view)

      # The form stays visible (no transition to :confirmation).
      assert html =~ "Enter Your Details"
      refute html =~ "Your answers"
    end
  end

  describe "booking flow with custom fields on Rhythm theme (T18)" do
    setup %{user: user} do
      base_mt =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Rhythm Custom Fields Chat",
          is_active: true
        )

      {:ok, mt} =
        MeetingTypes.update_meeting_type(base_mt, %{
          "custom_fields" => [
            %{
              "id" => "cf-rhythm-001",
              "type" => "short_text",
              "label" => "Company",
              "required" => true,
              "position" => 0
            }
          ]
        })

      %{meeting_type: mt}
    end

    @tag :capture_log
    test "Rhythm theme mounts and exposes the questions step via the engine", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type
    } do
      # Switch the profile to the Rhythm theme. The shared scheduling macro
      # wires the same engine and `:questions` state machine into both themes;
      # this test guards against regressions in the Rhythm-side mount and
      # `CustomQuestionsComponent` rendering. (A full booker-walks-the-wizard
      # test would need a theme-agnostic navigation helper, which is out of
      # scope here — the engine itself is covered end-to-end on Quill.)
      profile
      |> Changeset.change(booking_theme: "2")
      |> Repo.update!()

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=#{profile.timezone}")

      html = render(view)

      # The Rhythm overview page mounted successfully with the meeting type
      # present (so the scheduling pipeline can later route into `:questions`).
      assert html =~ meeting_type.name

      # Sanity-check that the underlying socket is using the Rhythm theme —
      # this is what wires in the Rhythm `CustomQuestionsComponent` once the
      # state machine reaches `:questions`.
      socket = :sys.get_state(view.pid).socket

      assert socket.assigns.theme_module == TymeslotWeb.Themes.Rhythm.Theme
      assert socket.assigns.theme_context.theme_key == :rhythm
    end
  end

  describe "booking flow without custom fields (regression)" do
    setup %{user: user} do
      mt =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "No Fields Chat",
          is_active: true
        )

      %{meeting_type: mt}
    end

    @tag :capture_log
    test "no questions step is rendered when meeting type has no custom fields",
         %{conn: conn, profile: profile} do
      # navigate_to_booking_form ends at :booking — no :questions detour.
      view = navigate_to_booking_form(conn, profile, nil)

      html = render(view)
      refute html =~ "Question 1 of"
      assert html =~ "Enter Your Details"
    end
  end

  describe "direct visit to the thank-you page" do
    @tag :capture_log
    test "renders without crashing when no booking data is present (Quill)",
         %{conn: conn, profile: profile} do
      # A direct GET to /:username/thank-you mounts the :confirmation state
      # without going through the booking submission handler, so the
      # custom_fields_snapshot / custom_field_answers assigns are never set by
      # that path. Safe defaults must keep the confirmation component from
      # raising a KeyError.
      {:ok, view, html} =
        live(conn, "/#{profile.username}/thank-you?timezone=#{profile.timezone}")

      assert html =~ "meeting" or html =~ "Meeting"
      socket = :sys.get_state(view.pid).socket
      assert socket.assigns.custom_fields_snapshot == []
      assert socket.assigns.custom_field_answers == %{}
    end

    @tag :capture_log
    test "renders without crashing when no booking data is present (Rhythm)",
         %{conn: conn, profile: profile} do
      profile
      |> Changeset.change(booking_theme: "2")
      |> Repo.update!()

      {:ok, view, _html} =
        live(conn, "/#{profile.username}/thank-you?timezone=#{profile.timezone}")

      socket = :sys.get_state(view.pid).socket
      assert socket.assigns.custom_fields_snapshot == []
      assert socket.assigns.custom_field_answers == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # When custom fields are present, the same booking-flow navigation that
  # lands on :booking instead routes to :questions — so the shared helper
  # leaves us on the questions step.
  defp navigate_to_booking_form_with_questions(conn, profile) do
    navigate_to_booking_form(conn, profile, nil)
  end
end
