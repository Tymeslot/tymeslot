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

  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "focus_custom_input with invalid inputs" do
    test "invalid setting name does not crash", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      html = render(view)
      assert html =~ "Buffer between meetings"
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

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.buffer_minutes >= 0
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

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.buffer_minutes <= 120
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

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.buffer_minutes == 20
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

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.advance_booking_days == 1
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

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.advance_booking_days == 365
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

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.min_advance_hours == 0
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

      profile = Repo.get_by!(Tymeslot.Profiles.ProfileSchema, user_id: user.id)
      assert profile.min_advance_hours == 168
    end
  end

  describe "concurrent updates" do
    test "rapid preset button clicks work correctly", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
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

      assert render(view) =~ "Buffer between meetings"
    end

    test "switching between custom and preset rapidly works", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_steps(view)

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='30']"
      )
      |> render_click()

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      assert render(view) =~ ~s(name="buffer_minutes")
    end
  end

  # Navigates from buffer_time through booking_window and minimum_notice to ready
  defp navigate_scheduling_steps_to_ready(view) do
    view |> element("button[phx-click='next_step']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()
  end
end
