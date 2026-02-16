defmodule TymeslotWeb.Themes.Quill.ThemeTest do
  use TymeslotWeb.ConnCase, async: true

  alias TymeslotWeb.Themes.Quill.Theme
  alias TymeslotWeb.ThemeCommonTestCases

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
    test "behaves according to common theme contract" do
      ThemeCommonTestCases.test_initial_state_for_action(Theme)
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
    test "behaves according to common theme contract" do
      ThemeCommonTestCases.test_render_meeting_action(Theme, &build_meeting_assigns/0)
    end
  end

  defp build_meeting_assigns do
    ThemeCommonTestCases.build_meeting_assigns("1", "turquoise", "gradient_2")
  end
end
