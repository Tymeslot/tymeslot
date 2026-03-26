defmodule TymeslotWeb.OnboardingCustomInputsTest do
  @moduledoc """
  Tests for custom value inputs in the onboarding scheduling preferences step.

  Tests the ability to:
  - Click "Custom" button to enable custom input
  - Enter custom values within valid ranges
  - Persist custom values across navigation and completion
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    ensure_rate_limiter_started()
    RateLimiter.clear_all()
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "buffer_minutes custom input" do
    test "clicking Custom button shows custom input field", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Click "Custom" button for buffer_minutes
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      html = render(view)

      # Should now show custom input
      assert html =~ ~s(name="buffer_minutes")
      assert html =~ ~s(type="number")
    end

    test "custom value persists through onboarding completion", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set custom buffer value (20 minutes)
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_minutes" => "20"})

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify custom value was saved
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      assert profile.buffer_minutes == 20
    end
  end

  describe "advance_booking_days custom input" do
    test "clicking Custom button shows custom input field", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Click "Custom" button
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      html = render(view)

      # Should show custom input
      assert html =~ ~s(name="advance_booking_days")
      assert html =~ ~s(type="number")
    end

    test "custom value persists through onboarding completion", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set custom value (100 days)
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"advance_booking_days" => "100"})

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify custom value was saved
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      assert profile.advance_booking_days == 100
    end
  end

  describe "min_advance_hours custom input" do
    test "clicking Custom button shows custom input field", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Click "Custom" button
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      html = render(view)

      # Should show custom input
      assert html =~ ~s(name="min_advance_hours")
      assert html =~ ~s(type="number")
    end

    test "custom value persists through onboarding completion", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set custom value (10 hours)
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"min_advance_hours" => "10"})

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify custom value was saved
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      assert profile.min_advance_hours == 10
    end
  end

  describe "custom values matching presets" do
    test "custom input remains visible when typing a value that matches a preset", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      setup_custom_input_and_change_value(view, "buffer_minutes", "15")

      # The custom input should still be visible (not switch back to "Custom" button)
      html = render(view)
      assert html =~ ~s(name="buffer_minutes")
      assert html =~ ~s(type="number")
      assert html =~ "value=\"15\""
    end

    test "preset button is not highlighted when in custom mode with matching value", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      setup_custom_input_and_change_value(view, "buffer_minutes", "15")

      html = render(view)

      # Custom input should be visible and active
      assert html =~ ~s(name="buffer_minutes")
      assert html =~ "btn-tag-selector-primary--active"

      # The "15 min" preset button should NOT have the active class.
      # Split on the custom input's name attribute to isolate the preset buttons section.
      [preset_buttons_section, _rest] =
        String.split(html, ~s(name="buffer_minutes"), parts: 2)

      refute preset_buttons_section =~ ~r/15 min.*btn-tag-selector-primary--active/s
    end

    test "custom input remains visible when typing a different preset value", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Click "Custom" for advance_booking_days
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      # Type a value that matches a preset (30 days)
      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"advance_booking_days" => "30"})

      # The custom input should still be visible
      html = render(view)
      assert html =~ ~s(name="advance_booking_days")
      assert html =~ ~s(type="number")
      assert html =~ "value=\"30\""
    end
  end

  describe "switching between presets and custom values" do
    test "can set multiple custom values and complete onboarding", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Click "Custom" for all three settings (they'll use default custom values)
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      # All custom inputs should be visible
      html = render(view)
      assert html =~ ~s(name="buffer_minutes")
      assert html =~ ~s(name="advance_booking_days")
      assert html =~ ~s(name="min_advance_hours")

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify custom values were saved (using defaults from focus_custom_input)
      # Default custom values from step_config.ex: buffer=20, advance=120, min=8
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      assert profile.buffer_minutes == 20
      assert profile.advance_booking_days == 120
      assert profile.min_advance_hours == 8
    end

    test "can switch from custom back to preset", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set custom value
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='buffer_minutes']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_minutes" => "25"})

      # Input should be visible
      assert render(view) =~ ~s(name="buffer_minutes")

      # Switch to preset value (30)
      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='30']"
      )
      |> render_click()

      # Should now show Custom button again (30 is a preset)
      html = render(view)
      assert html =~ "Custom"
      # "30 min" button should be active
      assert html =~ "btn-tag-selector-primary--active"
    end
  end

  # Helper functions

  defp setup_custom_input_and_change_value(view, setting, value) do
    # Click "Custom" button for the setting
    view
    |> element("button[phx-click='focus_custom_input'][phx-value-setting='#{setting}']")
    |> render_click()

    # Type the value
    view
    |> element("form[phx-change='update_scheduling_preferences']")
    |> render_change(%{setting => value})
  end
end
