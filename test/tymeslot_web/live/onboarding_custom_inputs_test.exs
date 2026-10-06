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

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "buffer_before_minutes custom input" do
    test "clicking Custom button shows custom input field", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Click "Custom" button for buffer_before_minutes
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='buffer_before_minutes']"
      )
      |> render_click()

      html = render(view)

      # Should now show custom input
      assert html =~ ~s(name="buffer_before_minutes")
      assert html =~ ~s(type="number")
    end

    test "custom value persists through onboarding completion", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set custom buffer value (20 minutes)
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='buffer_before_minutes']"
      )
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_before_minutes" => "20"})

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify custom value was saved
      schedule = default_schedule(user)
      assert schedule.buffer_before_minutes == 20
    end
  end

  describe "buffer rows accessibility" do
    test "each row's group, Custom button and custom input have their own accessible name", %{
      conn: conn
    } do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      rows = [
        {"onboarding-buffer-before", "buffer_before_minutes", "Custom buffer before, in minutes"},
        {"onboarding-buffer-after", "buffer_after_minutes", "Custom buffer after, in minutes"}
      ]

      for {id, field, name} <- rows do
        assert has_element?(view, "##{id} p##{id}-label")
        assert has_element?(view, "##{id} [role='group'][aria-labelledby='#{id}-label']")

        assert has_element?(
                 view,
                 "##{id} button[phx-value-setting='#{field}'][aria-label='#{name}']"
               )

        view |> element("##{id} button[phx-value-setting='#{field}']") |> render_click()

        assert has_element?(view, "##{id} input[name='#{field}'][aria-label='#{name}']")
      end
    end
  end

  describe "buffer_after_minutes custom input" do
    test "a custom after-buffer persists without touching the before-buffer", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='buffer_after_minutes']"
      )
      |> render_click()

      assert render(view) =~ ~s(name="buffer_after_minutes")

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_after_minutes" => "25"})

      schedule = default_schedule(user)
      assert {schedule.buffer_before_minutes, schedule.buffer_after_minutes} == {15, 25}
    end

    test "an out-of-range after-buffer is rejected and not saved", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='buffer_after_minutes']"
      )
      |> render_click()

      html =
        view
        |> element("form[phx-change='update_scheduling_preferences']")
        |> render_change(%{"buffer_after_minutes" => "999"})

      assert html =~ "Buffer after must be between 0 and 120 minutes."
      assert default_schedule(user).buffer_after_minutes == 20

      assert view
             |> element("#onboarding-buffer-after")
             |> render() =~ "Buffer after must be between 0 and 120 minutes."

      refute view
             |> element("#onboarding-buffer-before")
             |> render() =~ "must be between"
    end

    test "saving one buffer keeps the other buffer's unsaved error", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='buffer_after_minutes']"
      )
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_after_minutes" => "999"})

      view
      |> element("#onboarding-buffer-before button[phx-value-buffer_before_minutes='30']")
      |> render_click()

      schedule = default_schedule(user)
      assert {schedule.buffer_before_minutes, schedule.buffer_after_minutes} == {30, 20}

      assert view
             |> element("#onboarding-buffer-after")
             |> render() =~ "Buffer after must be between 0 and 120 minutes."
    end

    test "a buffer's invalid value does not stop the other buffer saving", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)
      focus_custom_buffer(view, "buffer_before_minutes")
      focus_custom_buffer(view, "buffer_after_minutes")

      # With both rows in custom mode, a change submits both inputs.
      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_before_minutes" => "200", "buffer_after_minutes" => "30"})

      schedule = default_schedule(user)
      assert {schedule.buffer_before_minutes, schedule.buffer_after_minutes} == {20, 30}

      assert view
             |> element("#onboarding-buffer-before")
             |> render() =~ "Buffer before must be between 0 and 120 minutes."

      refute view
             |> element("#onboarding-buffer-after")
             |> render() =~ "must be between"
    end

    # Both rows sit in one form, so editing one resubmits the other's refused
    # value. The refused field must go on showing what was typed beside its
    # error, never the saved value under an error that does not describe it.
    for {refused, edited} <- [
          {"buffer_before_minutes", "buffer_after_minutes"},
          {"buffer_after_minutes", "buffer_before_minutes"}
        ] do
      test "#{refused} keeps its refused value beside its error while #{edited} saves", %{
        conn: conn
      } do
        refused = unquote(refused)
        edited = unquote(edited)
        refused_row = "#onboarding-buffer-#{if refused =~ "before", do: "before", else: "after"}"
        {:ok, view, _html, user} = setup_onboarding(conn)
        navigate_to_scheduling_preferences(view)
        focus_custom_buffer(view, "buffer_before_minutes")
        focus_custom_buffer(view, "buffer_after_minutes")
        saved_refused = Map.fetch!(default_schedule(user), String.to_existing_atom(refused))

        form = element(view, "form[phx-change='update_scheduling_preferences']")
        render_change(form, %{refused => "130", edited => "20"})
        render_change(form, %{refused => "130", edited => "35"})

        schedule = default_schedule(user)
        assert Map.fetch!(schedule, String.to_existing_atom(edited)) == 35
        assert Map.fetch!(schedule, String.to_existing_atom(refused)) == saved_refused

        assert has_element?(view, "#{refused_row} input[name='#{refused}'][value='130']")
        assert view |> element(refused_row) |> render() =~ "must be between 0 and 120 minutes."

        # Correcting the refused value saves it, and the error goes with it.
        render_change(form, %{refused => "40", edited => "35"})

        assert Map.fetch!(default_schedule(user), String.to_existing_atom(refused)) == 40
        assert has_element?(view, "#{refused_row} input[name='#{refused}'][value='40']")
        refute view |> element(refused_row) |> render() =~ "must be between"
      end
    end

    test "a preset leaves custom mode while the other buffer holds an error", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)
      focus_custom_buffer(view, "buffer_after_minutes")
      focus_custom_buffer(view, "buffer_before_minutes")

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_before_minutes" => "200"})

      view
      |> element("#onboarding-buffer-after button[phx-value-buffer_after_minutes='15']")
      |> render_click()

      assert default_schedule(user).buffer_after_minutes == 15

      after_row = view |> element("#onboarding-buffer-after") |> render()
      refute after_row =~ ~s(name="buffer_after_minutes")
      assert after_row =~ "btn-tag-selector-primary--active"
    end
  end

  describe "advance_booking_days custom input" do
    test "clicking Custom button shows custom input field", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_booking_window_step(view)

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
      navigate_to_booking_window_step(view)

      # Set custom value (100 days)
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"advance_booking_days" => "100"})

      # Continue through remaining steps
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify custom value was saved
      schedule = default_schedule(user)
      assert schedule.advance_booking_days == 100
    end
  end

  describe "min_advance_hours custom input" do
    test "clicking Custom button shows custom input field", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_minimum_notice_step(view)

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
      navigate_to_minimum_notice_step(view)

      # Set custom value (10 hours)
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"min_advance_hours" => "10"})

      # Continue to the ready step
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify custom value was saved
      schedule = default_schedule(user)
      assert schedule.min_advance_hours == 10
    end
  end

  describe "custom values matching presets" do
    test "custom input remains visible when typing a value that matches a preset", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      setup_custom_input_and_change_value(view, "buffer_before_minutes", "15")

      # The custom input should still be visible (not switch back to "Custom" button)
      html = render(view)
      assert html =~ ~s(name="buffer_before_minutes")
      assert html =~ ~s(type="number")
      assert html =~ "value=\"15\""
    end

    test "preset button is not highlighted when in custom mode with matching value", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      setup_custom_input_and_change_value(view, "buffer_before_minutes", "15")

      html = render(view)

      # Custom input should be visible and active
      assert has_element?(
               view,
               "#onboarding-buffer-before .btn-tag-selector-primary--active input[name='buffer_before_minutes']"
             )

      # The "15 min" preset button should NOT have the active class.
      # Split on the custom input's name attribute to isolate the preset buttons section.
      [preset_buttons_section, _rest] =
        String.split(html, ~s(name="buffer_before_minutes"), parts: 2)

      # Match the HTML structure: class attribute appears BEFORE button text content.
      # The custom input wrapper also has --active, but its content is a text input field, not "15 min".
      refute preset_buttons_section =~ ~r/btn-tag-selector-primary--active[^>]*>\s*15 min/s
    end

    test "custom input remains visible when typing a different preset value", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_booking_window_step(view)

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

      # Step: buffer_time — set custom buffer (uses default_custom value: 20)
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='buffer_before_minutes']"
      )
      |> render_click()

      # Navigate to booking_window
      view |> element("button[phx-click='next_step']") |> render_click()

      # Step: booking_window — set custom advance booking (uses default_custom value: 120)
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      # Navigate to minimum_notice
      view |> element("button[phx-click='next_step']") |> render_click()

      # Step: minimum_notice — set custom min advance (uses default_custom value: 8)
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      # Verify all three custom values were saved to the database
      # Default custom values from step_config.ex: buffer=20, advance=120, min=8
      schedule = default_schedule(user)
      assert schedule.buffer_before_minutes == 20
      assert schedule.advance_booking_days == 120
      assert schedule.min_advance_hours == 8
    end

    test "can switch from custom back to preset", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set custom value
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='buffer_before_minutes']"
      )
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_before_minutes" => "25"})

      # Input should be visible
      assert render(view) =~ ~s(name="buffer_before_minutes")

      # Switch to preset value (30)
      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_before_minutes='30']"
      )
      |> render_click()

      # Should now show Custom button again (30 is a preset)
      refute has_element?(view, "input[name='buffer_before_minutes']")

      assert has_element?(
               view,
               "#onboarding-buffer-before button[phx-value-setting='buffer_before_minutes']"
             )

      # "30 min" button should be active
      assert has_element?(
               view,
               "#onboarding-buffer-before button.btn-tag-selector-primary--active[phx-value-buffer_before_minutes='30']"
             )
    end
  end

  describe "Continue with a refused value" do
    for value <- ["-10", "999"] do
      test "stays on the buffer step with the error shown for #{value}", %{conn: conn} do
        {:ok, view, _html, user} = setup_onboarding(conn)
        navigate_to_scheduling_preferences(view)

        setup_custom_input_and_change_value(view, "buffer_before_minutes", unquote(value))
        view |> element("button[phx-click='next_step']") |> render_click()

        assert has_element?(view, "#onboarding-buffer-time-form")
        refute has_element?(view, "#onboarding-booking-window-form")

        assert view
               |> element("#onboarding-buffer-before")
               |> render() =~ "Buffer before must be between 0 and 120 minutes."

        assert default_schedule(user).buffer_before_minutes == 20
      end
    end

    test "advances once the refused buffer is corrected", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      setup_custom_input_and_change_value(view, "buffer_after_minutes", "999")
      view |> element("button[phx-click='next_step']") |> render_click()
      assert has_element?(view, "#onboarding-buffer-time-form")

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"buffer_after_minutes" => "45"})

      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(view, "#onboarding-booking-window-form")
      assert default_schedule(user).buffer_after_minutes == 45
    end

    test "stays on the booking window step with a refused value", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      navigate_to_booking_window_step(view)

      setup_custom_input_and_change_value(view, "advance_booking_days", "0")
      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(view, "#onboarding-booking-window-form")
      refute has_element?(view, "#onboarding-min-notice-form")
    end
  end

  # Helper functions

  defp focus_custom_buffer(view, setting) do
    view
    |> element("button[phx-click='focus_custom_input'][phx-value-setting='#{setting}']")
    |> render_click()
  end

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
