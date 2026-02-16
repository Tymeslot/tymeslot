defmodule TymeslotWeb.Themes.Quill.ThemeTest do
  use TymeslotWeb.ConnCase, async: true

  alias TymeslotWeb.Themes.Quill.Theme

  describe "states/0" do
    test "returns a 4-step flow state machine" do
      states = Theme.states()

      assert map_size(states) == 4
      assert Map.has_key?(states, :overview)
      assert Map.has_key?(states, :schedule)
      assert Map.has_key?(states, :booking)
      assert Map.has_key?(states, :confirmation)
    end

    test "overview is step 1 with no previous step" do
      states = Theme.states()

      assert states.overview.step == 1
      assert states.overview.next == :schedule
      assert states.overview.prev == nil
    end

    test "schedule is step 2 linking overview and booking" do
      states = Theme.states()

      assert states.schedule.step == 2
      assert states.schedule.prev == :overview
      assert states.schedule.next == :booking
    end

    test "booking is step 3 linking schedule and confirmation" do
      states = Theme.states()

      assert states.booking.step == 3
      assert states.booking.prev == :schedule
      assert states.booking.next == :confirmation
    end

    test "confirmation is step 4 with no previous navigation" do
      states = Theme.states()

      assert states.confirmation.step == 4
      assert states.confirmation.prev == nil
    end
  end

  describe "css_file/0" do
    test "returns the Quill theme CSS asset path" do
      assert Theme.css_file() == "/assets/scheduling-theme-quill.css"
    end
  end

  describe "components/0" do
    test "maps all scheduling states to their component modules" do
      components = Theme.components()

      assert map_size(components) == 4
      assert components.overview == TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent
      assert components.schedule == TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent
      assert components.booking == TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent

      assert components.confirmation ==
               TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent
    end
  end

  describe "live_view_module/0" do
    test "returns the Quill scheduling LiveView module" do
      assert Theme.live_view_module() == TymeslotWeb.Themes.Quill.Scheduling.Live
    end
  end

  describe "theme_config/0" do
    test "provides theme metadata and capabilities" do
      config = Theme.theme_config()

      assert config.name == "Quill"
      assert config.flow_steps == 4
      assert config.design_system == :glassmorphism
      assert config.supports_duration_selection == true
      assert config.supports_inline_booking == false
      assert String.contains?(config.description, "Glass morphism")
      assert String.contains?(config.preview_image, "quill-theme-preview")
    end
  end

  describe "validate_theme/0" do
    test "returns :ok when all required components are loadable" do
      assert Theme.validate_theme() == :ok
    end
  end

  describe "initial_state_for_action/1" do
    test "maps :index action to overview state" do
      assert Theme.initial_state_for_action(:index) == :overview
    end

    test "maps each named action to its corresponding state" do
      assert Theme.initial_state_for_action(:overview) == :overview
      assert Theme.initial_state_for_action(:schedule) == :schedule
      assert Theme.initial_state_for_action(:booking) == :booking
      assert Theme.initial_state_for_action(:confirmation) == :confirmation
    end

    test "defaults unknown actions to overview" do
      assert Theme.initial_state_for_action(:unknown) == :overview
      assert Theme.initial_state_for_action(:random_action) == :overview
    end
  end

  describe "supports_feature?/1" do
    test "supports glassmorphism and calendar grid features" do
      assert Theme.supports_feature?(:duration_selection) == true
      assert Theme.supports_feature?(:step_navigation) == true
      assert Theme.supports_feature?(:glassmorphism) == true
      assert Theme.supports_feature?(:calendar_grid) == true
    end

    test "does not support inline booking" do
      assert Theme.supports_feature?(:inline_booking) == false
    end

    test "returns false for unknown features" do
      assert Theme.supports_feature?(:unknown_feature) == false
      assert Theme.supports_feature?(:video_background) == false
    end
  end

  describe "render_meeting_action/2" do
    test "renders reschedule action with proper assigns" do
      assigns = build_meeting_assigns()
      result = Theme.render_meeting_action(assigns, :reschedule)

      assert result.__struct__ == Phoenix.LiveView.Rendered
    end

    test "renders cancel action with proper assigns" do
      assigns = build_meeting_assigns()
      result = Theme.render_meeting_action(assigns, :cancel)

      assert result.__struct__ == Phoenix.LiveView.Rendered
    end

    test "renders cancel_confirmed action with proper assigns" do
      assigns = build_meeting_assigns()
      result = Theme.render_meeting_action(assigns, :cancel_confirmed)

      assert result.__struct__ == Phoenix.LiveView.Rendered
    end

    test "raises error for unsupported actions" do
      assigns = build_meeting_assigns()

      assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
        Theme.render_meeting_action(assigns, :invalid)
      end
    end
  end

  defp build_meeting_assigns do
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
        theme_id: "1",
        color_scheme: "turquoise",
        background_type: "gradient",
        background_value: "gradient_2"
      },
      custom_css: nil,
      locale: "en",
      language_dropdown_open: false
    }
  end
end
