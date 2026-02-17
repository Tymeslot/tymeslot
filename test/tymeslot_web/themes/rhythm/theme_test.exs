defmodule TymeslotWeb.Themes.Rhythm.ThemeTest do
  use TymeslotWeb.ConnCase, async: true

  alias TymeslotWeb.ThemeCommonTestCases
  alias TymeslotWeb.Themes.Rhythm.Theme

  describe "states/0" do
    test "returns a 4-step flow state machine" do
      ThemeCommonTestCases.test_states_structure(Theme)
    end

    test "state flow configuration" do
      ThemeCommonTestCases.test_state_flow(Theme, :booking)
    end
  end

  describe "css_file/0" do
    test "returns the Rhythm theme CSS asset path" do
      assert Theme.css_file() == "/assets/scheduling-theme-rhythm.css"
    end
  end

  describe "components/0" do
    test "maps all scheduling states to their component modules" do
      ThemeCommonTestCases.test_components_mapping(
        Theme,
        TymeslotWeb.Themes.Rhythm.Scheduling.Components.OverviewComponent,
        TymeslotWeb.Themes.Rhythm.Scheduling.Components.ScheduleComponent,
        TymeslotWeb.Themes.Rhythm.Scheduling.Components.BookingComponent,
        TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent
      )
    end
  end

  describe "live_view_module/0" do
    test "returns the Rhythm scheduling LiveView module" do
      assert Theme.live_view_module() == TymeslotWeb.Themes.Rhythm.Scheduling.Live
    end
  end

  describe "theme_config/0" do
    test "provides theme metadata and capabilities" do
      config = Theme.theme_config()

      assert config.name == "Rhythm"
      assert config.flow_steps == 4
      assert config.design_system == :video_background
      assert config.supports_duration_selection == true
      assert config.supports_inline_booking == false
      assert String.contains?(config.description, "video background")
      assert String.contains?(config.preview_image, "rhythm-theme-preview")
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
    test "supports video background and slide navigation features" do
      assert Theme.supports_feature?(:duration_selection) == true
      assert Theme.supports_feature?(:step_navigation) == true
      assert Theme.supports_feature?(:slide_navigation) == true
      assert Theme.supports_feature?(:video_background) == true
      assert Theme.supports_feature?(:compact_design) == true
    end

    test "does not support inline booking" do
      assert Theme.supports_feature?(:inline_booking) == false
    end

    test "returns false for unknown features" do
      assert Theme.supports_feature?(:unknown_feature) == false
      assert Theme.supports_feature?(:glassmorphism) == false
    end
  end

  describe "render_meeting_action/2" do
    test "behaves according to common theme contract" do
      ThemeCommonTestCases.test_render_meeting_action(Theme, &build_meeting_assigns/0)
    end
  end

  defp build_meeting_assigns do
    ThemeCommonTestCases.build_meeting_assigns("2", "purple", "gradient_1")
  end
end
