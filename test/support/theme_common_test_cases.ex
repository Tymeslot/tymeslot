defmodule TymeslotWeb.ThemeCommonTestCases do
  @moduledoc """
  Shared test cases for common theme behavior that all themes must implement.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  @doc """
  Tests the standard 4-step state machine structure.
  """
  @spec test_states_structure(module()) :: :ok
  def test_states_structure(theme_module) do
    states = theme_module.states()

    assert map_size(states) == 4
    assert Map.has_key?(states, :overview)
    assert Map.has_key?(states, :schedule)
    assert Map.has_key?(states, :booking)
    assert Map.has_key?(states, :confirmation)
  end

  @doc """
  Tests the state flow configuration for a 4-step theme.
  Allows customization of confirmation's previous state.
  """
  @spec test_state_flow(module(), atom() | nil) :: :ok
  def test_state_flow(theme_module, confirmation_prev \\ nil) do
    states = theme_module.states()

    # Overview: step 1, no previous
    assert states.overview.step == 1
    assert states.overview.next == :schedule
    assert states.overview.prev == nil

    # Schedule: step 2, links overview and booking
    assert states.schedule.step == 2
    assert states.schedule.prev == :overview
    assert states.schedule.next == :booking

    # Booking: step 3, links schedule and confirmation
    assert states.booking.step == 3
    assert states.booking.prev == :schedule
    assert states.booking.next == :confirmation

    # Confirmation: step 4, configurable previous
    assert states.confirmation.step == 4
    assert states.confirmation.prev == confirmation_prev
  end

  @doc """
  Tests that components map to expected modules.
  """
  @spec test_components_mapping(module(), module(), module(), module(), module()) :: :ok
  def test_components_mapping(
        theme_module,
        overview_component,
        schedule_component,
        booking_component,
        confirmation_component
      ) do
    components = theme_module.components()

    assert map_size(components) == 4
    assert components.overview == overview_component
    assert components.schedule == schedule_component
    assert components.booking == booking_component
    assert components.confirmation == confirmation_component
  end

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

    reschedule = render_meeting_action_html(theme_module, assigns, :reschedule)
    assert reschedule =~ "Reschedule Appointment"
    assert reschedule =~ "Select a new time for your meeting"
    refute reschedule =~ "Yes, Cancel Meeting"

    cancel = render_meeting_action_html(theme_module, assigns, :cancel)
    assert cancel =~ "Cancel Appointment"
    assert cancel =~ "Are you sure you want to cancel this appointment?"
    assert cancel =~ "Yes, Cancel Meeting"
    assert cancel =~ "Keep Meeting"

    kept =
      render_meeting_action_html(theme_module, Map.put(assigns, :meeting_kept, true), :cancel)

    assert kept =~ "Meeting Confirmed"
    assert kept =~ "Great! Your meeting is still scheduled as planned."
    refute kept =~ "Yes, Cancel Meeting"

    cancel_confirmed = render_meeting_action_html(theme_module, assigns, :cancel_confirmed)
    assert cancel_confirmed =~ "Meeting Cancelled"
    assert cancel_confirmed =~ "Your meeting has been successfully cancelled."
    assert cancel_confirmed =~ "Schedule a New Meeting"
    refute cancel_confirmed =~ "Are you sure you want to cancel this appointment?"

    # Test unsupported action raises error
    assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
      theme_module.render_meeting_action(assigns, :invalid)
    end

    :ok
  end

  defp render_meeting_action_html(theme_module, assigns, action) do
    result = theme_module.render_meeting_action(assigns, action)
    assert %Phoenix.LiveView.Rendered{} = result
    rendered_to_string(result)
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
      language_dropdown_open: false,
      loading: false,
      meeting_kept: false
    }
  end
end
