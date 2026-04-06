defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModal

  @preferences %{
    week_start_day: "monday",
    time_format: "24h",
    default_view: "week",
    show_week_numbers: false,
    show_weekends: true
  }

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        preferences: @preferences,
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      },
      overrides
    )
  end

  test "renders all settings sections" do
    html = render_component(&SettingsModal.settings_modal/1, base_assigns())

    assert html =~ "Calendar Settings"
    assert html =~ "First day of week"
    assert html =~ "Time format"
    assert html =~ "Default view"
    assert html =~ "Week numbers"
    assert html =~ "Show weekends"
  end

  test "renders toggle options for week start" do
    html = render_component(&SettingsModal.settings_modal/1, base_assigns())

    assert html =~ "Mon"
    assert html =~ "Sun"
  end

  test "renders toggle options for time format" do
    html = render_component(&SettingsModal.settings_modal/1, base_assigns())

    assert html =~ "12h"
    assert html =~ "24h"
  end

  test "renders toggle options for default view" do
    html = render_component(&SettingsModal.settings_modal/1, base_assigns())

    assert html =~ "Day"
    assert html =~ "Week"
    assert html =~ "Month"
  end

  test "handles atom preference values" do
    prefs = %{@preferences | week_start_day: :monday, time_format: :"12h", default_view: :week}
    html = render_component(&SettingsModal.settings_modal/1, base_assigns(%{preferences: prefs}))

    assert html =~ "Calendar Settings"
  end
end
