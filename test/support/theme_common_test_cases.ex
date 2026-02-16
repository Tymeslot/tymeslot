defmodule TymeslotWeb.ThemeCommonTestCases do
  @moduledoc """
  Shared test cases for common theme behavior that all themes must implement.
  """

  import ExUnit.Assertions

  @doc """
  Tests the `initial_state_for_action/1` function common to all themes.
  Expects the theme module as the first argument.
  """
  @spec test_initial_state_for_action(module()) :: :ok
  def test_initial_state_for_action(theme_module) do
    assert theme_module.initial_state_for_action(:index) == :overview

    assert theme_module.initial_state_for_action(:overview) == :overview
    assert theme_module.initial_state_for_action(:schedule) == :schedule
    assert theme_module.initial_state_for_action(:booking) == :booking
    assert theme_module.initial_state_for_action(:confirmation) == :confirmation

    assert theme_module.initial_state_for_action(:unknown) == :overview
    assert theme_module.initial_state_for_action(:random_action) == :overview
  end

  @doc """
  Tests the `render_meeting_action/2` function common to all themes.
  Expects the theme module and a function to build meeting assigns.
  """
  @spec test_render_meeting_action(module(), (-> map())) :: :ok
  def test_render_meeting_action(theme_module, build_assigns_fn) do
    assigns = build_assigns_fn.()

    # Test reschedule action
    result = theme_module.render_meeting_action(assigns, :reschedule)
    assert result.__struct__ == Phoenix.LiveView.Rendered

    # Test cancel action
    result = theme_module.render_meeting_action(assigns, :cancel)
    assert result.__struct__ == Phoenix.LiveView.Rendered

    # Test cancel_confirmed action
    result = theme_module.render_meeting_action(assigns, :cancel_confirmed)
    assert result.__struct__ == Phoenix.LiveView.Rendered

    # Test unsupported action raises error
    assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
      theme_module.render_meeting_action(assigns, :invalid)
    end
  end

  @doc """
  Builds default meeting assigns with theme-specific overrides.
  """
  @spec build_meeting_assigns(String.t(), String.t(), String.t()) :: map()
  def build_meeting_assigns(theme_id, color_scheme, background_value) do
    %{
      meeting: %{
        uid: "test-123",
        start_time: ~U[2026-02-20 10:00:00Z],
        duration: 30,
        organizer_name: "Test User",
        attendee_timezone: "UTC"
      },
      organizer_profile: %{username: "testuser"},
      theme_customization: %{
        theme_id: theme_id,
        color_scheme: color_scheme,
        background_type: "gradient",
        background_value: background_value
      },
      custom_css: nil,
      locale: "en",
      language_dropdown_open: false
    }
  end
end
