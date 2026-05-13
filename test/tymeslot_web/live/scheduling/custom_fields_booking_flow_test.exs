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

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes
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
      |> element("input[name='value']")
      |> render_blur(%{"value" => "Acme Corp"})

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
      [meeting] = MeetingQueries.list_meetings_by_attendee_email("jane.cf@example.com")

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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Like `navigate_to_booking_form/3` but expects a :questions step in
  # between :schedule and :booking, so it stops after picking the time slot
  # and clicking next_step (which routes to :questions when custom fields
  # are present).
  defp navigate_to_booking_form_with_questions(conn, profile) do
    timezone = profile.timezone
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{timezone}")

    view |> element("button[data-testid='duration-option']") |> render_click()
    view |> element("button[data-testid='next-step']") |> render_click()

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

    # Next step routes to :questions when custom fields are present.
    view |> element("button[phx-click='next_step']") |> render_click()

    view
  end
end
