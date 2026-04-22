defmodule TymeslotWeb.Live.Dashboard.Availability.ListComponentCompositionTest do
  @moduledoc """
  Composition tests for the availability editor's `add_break` pipeline
  — the LiveComponent → `AvailabilityInputValidation.validate_break_input/2`
  → `AvailabilityActions.add_break/4` seam.

  Existing coverage (do not duplicate):

    * `tymeslot/availability/input_validation_test.exs` — exhaustive
      unit tests for `validate_day_hours/2`, `validate_break_input/2`,
      `validate_quick_break_input/2` (valid, boundary, malformed time,
      start=end, start>end, oversized labels, zero/negative/exceeds-max
      durations, non-numeric durations). If validation logic regresses,
      those tests catch it.
    * `tymeslot_web/live/dashboard/availability_live_test.exs` —
      happy-path LiveView tests for add_break / delete_break /
      toggle-off day / clear-day.

  What was missing: the **LiveComponent → validation → form_errors →
  re-render seam**. The plan calls out several rejection variants
  (malformed time, oversized label, break spanning midnight,
  overlapping breaks); the ones reachable from the dropdown-driven UI
  are the label rule (free-text field) and the start≥end rule (the UI
  lets the user pick any two dropdown times).

  Dropped from the plan with rationale:

    * `quick_break` with empty/nil/oversized duration — no UI button
      emits the `quick_break` event today. The handler at
      `list_component.ex:210` is currently unreachable from the
      rendered template. Its input-validation rules are already
      exhaustively covered in
      `input_validation_test.exs` (`validate_quick_break_input/2`
      describe block).
    * `validate_break` errors "not silently swallowed" — the handler
      at `list_component.ex:90` deliberately swallows change-event
      errors (the UI uses time dropdowns, so change-event validation
      is logging-only; real validation runs on submit). Asserting
      against that behaviour would contradict the code's stated
      intent.
    * `validate_day_hours` with 25:00 / missing times / start≥end —
      pinned at the unit level. The LiveView's `validate_day_hours`
      handler assigns errors to `:form_errors`; no user-visible flash
      is emitted because the dropdown UI cannot produce the
      malformed shapes, so the LiveView seam adds nothing beyond
      what the unit tests already cover.

  The single remaining high-value scenario: a client bypass that
  submits `add_break` with start ≥ end must surface a form error and
  not persist a nonsensical break window — the UI uses dropdowns, but
  nothing enforces start < end client-side.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :availability
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Availability.Breaks
  alias Tymeslot.Availability.WeeklySchedule

  setup :setup_dashboard_user

  setup %{user: user, profile: profile} = ctx do
    # Ensure the profile has a full weekly schedule; list_component
    # reads it via `weekly_schedule` assigns.
    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: day_of_week <= 5,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    Map.merge(ctx, %{user: user, profile: profile})
  end

  describe "add_break — end-before-start bypass" do
    @tag :capture_log
    test "start time after end time is rejected and no break row is created",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
      |> render_click()

      # Client-bypass: UI dropdowns do not enforce start < end, so
      # the server-side validation must reject.
      view
      |> form("form[phx-submit='add_break']", %{
        "day" => "1",
        "start" => "14:00",
        "end" => "13:00",
        "label" => "Impossible Break"
      })
      |> render_submit()

      html = render(view)
      refute html =~ "Break added"
      refute html =~ "Impossible Break"
      assert html =~ "End time must be after start time"

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert Breaks.get_breaks_for_day(day.id) == []
    end
  end

  describe "add_break — oversized label" do
    @tag :capture_log
    test "label exceeding 50 characters is rejected and no break row is created",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
      |> render_click()

      # The free-text label field is the only surface where an
      # oversized value can reach the server from the real UI.
      oversized_label = String.duplicate("a", 51)

      view
      |> form("form[phx-submit='add_break']", %{
        "day" => "1",
        "start" => "12:00",
        "end" => "13:00",
        "label" => oversized_label
      })
      |> render_submit()

      html = render(view)
      refute html =~ "Break added"
      refute html =~ oversized_label
      assert html =~ "Break label must be 50 characters or less"

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert Breaks.get_breaks_for_day(day.id) == []
    end
  end
end
