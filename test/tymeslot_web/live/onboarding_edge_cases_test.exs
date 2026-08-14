defmodule TymeslotWeb.OnboardingEdgeCasesTest do
  @moduledoc """
  Edge case and error handling tests for onboarding custom input functionality.

  Tests scenarios like:
  - Invalid setting names
  - Validation failures preserving state
  - Non-numeric inputs
  - Boundary values
  - Security edge cases (preset spoofing)
  - State preservation across navigation
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "focus_custom_input with invalid inputs" do
    test "invalid setting name does not crash and leaves state unchanged", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      # Dispatch the event with an unknown setting — the handler's `with` clause
      # falls through to `else _other -> {:noreply, socket}` without crashing.
      html = render_click(view, "focus_custom_input", %{"setting" => "nonexistent_field"})

      # Still on the buffer_time step.
      assert html =~ "Buffer between meetings"
      # No custom input was revealed (custom_input_mode unchanged).
      refute html =~ ~s(name="buffer_minutes")
    end
  end

  describe "direct navigation to a step outside the active sequence" do
    test "choose_theme without a connected calendar redirects, not crash", %{conn: conn} do
      # choose_theme is only in the step sequence once a calendar is connected.
      # Navigating straight to its URL without one used to assign an
      # out-of-sequence step and crash on the next advance; it must redirect.
      {conn, _user} = onboarding_conn(conn)

      assert {:error, {:redirect, %{to: "/onboarding"}}} =
               live(conn, "/onboarding/choose_theme")
    end
  end

  describe "update_scheduling_preferences with boundary values" do
    test "negative buffer_minutes value is rejected", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_minutes" => "-10"})

      # Navigate through remaining steps to ready
      navigate_scheduling_steps_to_ready(view)

      schedule = default_schedule(user)
      assert schedule.buffer_minutes >= 0
    end

    test "exceeding maximum buffer_minutes is rejected", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_minutes" => "999"})

      navigate_scheduling_steps_to_ready(view)

      schedule = default_schedule(user)
      assert schedule.buffer_minutes <= 120
    end
  end

  describe "preset spoofing security" do
    test "cannot spoof preset marker with non-preset value", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      assert render(view) =~ ~s(name="buffer_minutes")

      # Try to spoof: non-preset value (20) with _preset marker
      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_minutes" => "20", "_preset" => "true"})

      # Custom mode should remain active (spoofing caught)
      html = render(view)
      assert html =~ ~s(name="buffer_minutes")

      navigate_scheduling_steps_to_ready(view)

      schedule = default_schedule(user)
      assert schedule.buffer_minutes == 20
    end

    test "preset marker is verified for actual preset values", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='15']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "Custom"
    end
  end

  describe "custom_input_mode state preservation" do
    test "validation errors preserve custom mode state", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      # Navigate to booking_window step
      view |> element("button[phx-click='next_step']") |> render_click()

      refute render(view) =~ ~s(name="advance_booking_days")

      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      assert render(view) =~ ~s(name="advance_booking_days")

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"advance_booking_days" => "0"})

      html = render(view)
      assert html =~ ~s(name="advance_booking_days")
    end

    test "navigating back preserves custom_input_mode state", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_minutes" => "25"})

      # Navigate forward then back
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='previous_step']") |> render_click()

      html = render(view)
      assert html =~ ~s(name="buffer_minutes")
      assert html =~ "25"
    end
  end

  describe "boundary value testing" do
    test "advance_booking_days accepts minimum value (1)", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      # Navigate to booking_window step
      view |> element("button[phx-click='next_step']") |> render_click()

      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"advance_booking_days" => "1"})

      # booking_window → minimum_notice → ready
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      schedule = default_schedule(user)
      assert schedule.advance_booking_days == 1
    end

    test "advance_booking_days accepts maximum value (365)", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      # Navigate to booking_window step
      view |> element("button[phx-click='next_step']") |> render_click()

      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-advance_booking_days='365']"
      )
      |> render_click()

      # booking_window → minimum_notice → ready
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      schedule = default_schedule(user)
      assert schedule.advance_booking_days == 365
    end

    test "min_advance_hours accepts zero", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      # Navigate to minimum_notice step (buffer_time → booking_window → minimum_notice)
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-min_advance_hours='0']"
      )
      |> render_click()

      # minimum_notice → ready
      view |> element("button[phx-click='next_step']") |> render_click()

      schedule = default_schedule(user)
      assert schedule.min_advance_hours == 0
    end

    test "min_advance_hours accepts maximum (168)", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      # Navigate to minimum_notice step
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"min_advance_hours" => "168"})

      # minimum_notice → ready
      view |> element("button[phx-click='next_step']") |> render_click()

      schedule = default_schedule(user)
      assert schedule.min_advance_hours == 168
    end
  end

  describe "concurrent updates" do
    test "rapid preset button clicks settle on the last-clicked value", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='15']"
      )
      |> render_click()

      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='30']"
      )
      |> render_click()

      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='45']"
      )
      |> render_click()

      schedule = default_schedule(user)
      assert schedule.buffer_minutes == 45
    end

    test "switching through preset and back to custom seeds the default custom value", %{
      conn: conn
    } do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      # Enter custom mode (seeds buffer_minutes to default_custom = 20).
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      # Click a preset — exits custom mode, persists 30.
      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='30']"
      )
      |> render_click()

      # Re-enter custom mode: current value (30) is a preset, so seeds to default_custom = 20.
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      # Custom input is visible.
      assert render(view) =~ ~s(name="buffer_minutes")
      # The re-seeded value (20) was persisted, not the last preset (30).
      schedule = default_schedule(user)
      assert schedule.buffer_minutes == 20
    end
  end

  # Navigates from buffer_time through booking_window and minimum_notice to ready
  defp navigate_scheduling_steps_to_ready(view) do
    view |> element("button[phx-click='next_step']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()
  end
end
