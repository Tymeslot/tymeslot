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
    show_weekends: true,
    desktop_reminders_enabled: false
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
    assert html =~ "Desktop reminders"
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

  test "string preference values mark the stored option as active" do
    prefs = %{@preferences | week_start_day: "sunday", time_format: "24h", default_view: "month"}
    html = render_component(&SettingsModal.settings_modal/1, base_assigns(%{preferences: prefs}))

    assert active_option(html, "week-start-toggle") == "sunday"
    assert active_option(html, "time-format-toggle") == "24h"
    assert active_option(html, "default-view-toggle") == "month"
  end

  # Characterises current behaviour: `safe_to_atom/2` only maps binaries, so an
  # atom preference falls through its catch-all and is silently replaced by the
  # default. Values differing from the defaults are used deliberately — with
  # `:monday`/`:"12h"`/`:week` the discard is invisible.
  test "atom preference values are discarded and fall back to the defaults" do
    prefs = %{@preferences | week_start_day: :sunday, time_format: :"24h", default_view: :month}
    html = render_component(&SettingsModal.settings_modal/1, base_assigns(%{preferences: prefs}))

    assert active_option(html, "week-start-toggle") == "monday"
    assert active_option(html, "time-format-toggle") == "12h"
    assert active_option(html, "default-view-toggle") == "week"
  end

  # The active toggle option is the button carrying `btn-primary`; its id is
  # "<toggle-id>-<value>".
  defp active_option(html, toggle_id) do
    active =
      html
      |> Floki.parse_fragment!()
      |> Floki.find("button[id^='#{toggle_id}-'].btn-primary")
      |> Enum.map(fn button ->
        button
        |> Floki.attribute("id")
        |> hd()
        |> String.replace_prefix("#{toggle_id}-", "")
      end)

    case active do
      [value] -> value
      other -> other
    end
  end
end
