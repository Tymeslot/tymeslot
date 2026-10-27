defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.SettingsModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

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

  # Guards the layout that keeps a long description from running underneath
  # its control: the text column may shrink and wrap, the control may not.
  test "every control sits in a non-shrinking column beside a wrapping text column" do
    rows =
      (&SettingsModal.settings_modal/1)
      |> render_component(base_assigns())
      |> Floki.parse_fragment!()
      |> Floki.find("[data-testid='preference-row']")

    control_ids =
      Enum.flat_map(rows, fn row ->
        assert [text_class] = row |> Floki.find("div.flex-1") |> Floki.attribute("class")
        assert text_class =~ "min-w-0"

        row
        |> Floki.find("[data-testid='preference-control'].shrink-0 [id]")
        |> Floki.attribute("id")
      end)

    for id <-
          ~w(week-start-toggle time-format-toggle default-view-toggle week-numbers-switch weekends-switch desktop-reminders-switch) do
      assert Enum.any?(control_ids, &String.starts_with?(&1, id)),
             "#{id} is not in a shrink-0 control column"
    end
  end

  # The active option is the button pressed in the segmented control; its id
  # is "<toggle-id>-<value>".
  defp active_option(html, toggle_id) do
    active =
      html
      |> Floki.parse_fragment!()
      |> Floki.find("button[id^='#{toggle_id}-'][aria-pressed='true']")
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
