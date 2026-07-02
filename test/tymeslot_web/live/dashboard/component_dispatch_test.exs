defmodule TymeslotWeb.Dashboard.ComponentDispatchTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Tymeslot.Agenda.Day
  alias TymeslotWeb.Dashboard.AutomationSettingsComponent
  alias TymeslotWeb.Dashboard.BookingsManagementComponent
  alias TymeslotWeb.Dashboard.CalendarGridComponent
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Dashboard.ComponentDispatch
  alias TymeslotWeb.Dashboard.DashboardOverviewComponent
  alias TymeslotWeb.Dashboard.ProfileSettingsComponent
  alias TymeslotWeb.Dashboard.ScheduleSettingsComponent
  alias TymeslotWeb.Dashboard.ServiceSettingsComponent
  alias TymeslotWeb.Dashboard.ThemeSettingsComponent
  alias TymeslotWeb.Dashboard.VideoSettingsComponent
  alias TymeslotWeb.Live.Dashboard.EmbedSettingsComponent

  describe "component_id/1" do
    test "stringifies the action atom" do
      assert ComponentDispatch.component_id(:meeting_settings) == "meeting_settings"
      assert ComponentDispatch.component_id(:calendar) == "calendar"
    end
  end

  describe "component_for_action/2 — built-in actions" do
    @core_mapping [
      {:overview, DashboardOverviewComponent},
      {:settings, ProfileSettingsComponent},
      {:availability, ScheduleSettingsComponent},
      {:meeting_settings, ServiceSettingsComponent},
      {:calendar, CalendarGridComponent},
      {:calendar_integration, CalendarSettingsComponent},
      {:video_integration, VideoSettingsComponent},
      {:automation, AutomationSettingsComponent},
      {:theme, ThemeSettingsComponent},
      {:theme_customization, ThemeSettingsComponent},
      {:meetings, BookingsManagementComponent},
      {:embed, EmbedSettingsComponent}
    ]

    for {action, expected} <- @core_mapping do
      test "#{action} resolves to #{inspect(expected)}" do
        # The extensions map must not override a built-in action.
        assert ComponentDispatch.component_for_action(unquote(action), %{
                 unquote(action) => :should_be_ignored
               }) == unquote(expected)
      end
    end
  end

  describe "component_for_action/2 — extension fallback" do
    test "resolves an unknown action to its registered extension component" do
      assert ComponentDispatch.component_for_action(:my_extension, %{
               my_extension: SomeExternalComponent
             }) == SomeExternalComponent
    end

    test "falls back to DashboardOverviewComponent when no extension is registered" do
      assert ComponentDispatch.component_for_action(:unknown, %{}) ==
               DashboardOverviewComponent
    end

    test "tolerates a nil extensions map" do
      assert ComponentDispatch.component_for_action(:unknown, nil) ==
               DashboardOverviewComponent
    end
  end

  describe "props_for_action/1" do
    test ":overview surfaces the agenda as shared_data" do
      agenda = %Day{today: [%{id: 1}]}
      assigns = %{live_action: :overview, agenda: agenda}

      assert ComponentDispatch.props_for_action(assigns) == %{shared_data: %{agenda: agenda}}
    end

    test ":overview defaults the agenda to an empty Day when missing" do
      assert ComponentDispatch.props_for_action(%{live_action: :overview}) ==
               %{shared_data: %{agenda: %Day{}}}
    end

    test ":settings prefills the profile timezone from the detected timezone" do
      assigns = %{
        live_action: :settings,
        profile: %{timezone: nil},
        detected_timezone: "Europe/London"
      }

      assert %{profile: %{timezone: "Europe/London"}} =
               ComponentDispatch.props_for_action(assigns)
    end

    test ":availability prefills the profile timezone from the detected timezone" do
      assigns = %{
        live_action: :availability,
        profile: %{timezone: nil},
        detected_timezone: "Europe/London"
      }

      assert %{profile: %{timezone: "Europe/London"}} =
               ComponentDispatch.props_for_action(assigns)
    end

    test ":settings keeps an existing profile timezone instead of overriding" do
      assigns = %{
        live_action: :settings,
        profile: %{timezone: "America/New_York"},
        detected_timezone: "Europe/London"
      }

      assert %{profile: %{timezone: "America/New_York"}} =
               ComponentDispatch.props_for_action(assigns)
    end

    test "other actions return an empty prop map" do
      assert ComponentDispatch.props_for_action(%{live_action: :calendar}) == %{}
      assert ComponentDispatch.props_for_action(%{live_action: :automation}) == %{}
      assert ComponentDispatch.props_for_action(%{live_action: :embed}) == %{}
    end
  end

  describe "should_render_feature?/2" do
    test "returns true when no feature gates are configured" do
      assert ComponentDispatch.should_render_feature?(:meetings, %{})
    end

    test "returns true when the action is not in the gates map" do
      assigns = %{dashboard_feature_gates: %{automation: :automations_allowed}}
      assert ComponentDispatch.should_render_feature?(:meetings, assigns)
    end

    test "returns the assign value pointed to by the gate" do
      assigns = %{
        dashboard_feature_gates: %{automation: :automations_allowed},
        automations_allowed: true
      }

      assert ComponentDispatch.should_render_feature?(:automation, assigns)
    end

    test "returns false when the gating assign is false" do
      assigns = %{
        dashboard_feature_gates: %{automation: :automations_allowed},
        automations_allowed: false
      }

      refute ComponentDispatch.should_render_feature?(:automation, assigns)
    end

    test "defaults to true when the gating assign is missing entirely" do
      assigns = %{dashboard_feature_gates: %{automation: :automations_allowed}}
      assert ComponentDispatch.should_render_feature?(:automation, assigns)
    end
  end
end
