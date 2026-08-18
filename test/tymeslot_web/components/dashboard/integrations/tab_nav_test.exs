defmodule TymeslotWeb.Components.Dashboard.Integrations.TabNavTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.TabNav

  defp render_nav(assigns) do
    render_component(&TabNav.integrations_tab_nav/1, Map.new(assigns))
  end

  defp tabs do
    [
      %{id: :calendars, label: "Calendars", count: 3, status: :ok},
      %{id: :video, label: "Video", count: nil, status: :warning},
      %{id: :payments, label: "Payments", count: nil, status: :ok}
    ]
  end

  describe "integrations_tab_nav/1" do
    test "renders one patch link per tab" do
      html = render_nav(active_tab: :calendars, tabs: tabs())

      assert html =~ ~s(href="/dashboard/integrations?tab=calendars")
      assert html =~ ~s(href="/dashboard/integrations?tab=video")
      assert html =~ ~s(href="/dashboard/integrations?tab=payments")
      assert html =~ "Calendars"
      assert html =~ "Video"
      assert html =~ "Payments"
    end

    test "marks the active tab, and only it, as selected and underlined" do
      doc = Floki.parse_fragment!(render_nav(active_tab: :video, tabs: tabs()))

      # "some tab is true and some tab is false" is equally true of an inverted
      # comparison, so each tab's own value is pinned.
      assert Floki.attribute(doc, "#tab-video", "aria-selected") == ["true"]
      assert Floki.attribute(doc, "#tab-calendars", "aria-selected") == ["false"]
      assert Floki.attribute(doc, "#tab-payments", "aria-selected") == ["false"]

      # The turquoise underline must land on the same tab.
      assert [video_class] = Floki.attribute(doc, "#tab-video", "class")
      assert video_class =~ "text-turquoise-700"
      assert [calendars_class] = Floki.attribute(doc, "#tab-calendars", "class")
      refute calendars_class =~ "text-turquoise-700"
    end

    test "renders an amber dot for a :warning tab" do
      html = render_nav(active_tab: :calendars, tabs: tabs())

      assert html =~ "bg-amber-500"
      assert html =~ ~s(aria-hidden="true")
    end

    test "renders a red dot for an :error tab" do
      error_tabs = [%{id: :calendars, label: "Calendars", count: nil, status: :error}]
      html = render_nav(active_tab: :calendars, tabs: error_tabs)

      assert html =~ "bg-red-500"
    end

    test "renders the count as a pill when present" do
      html = render_nav(active_tab: :calendars, tabs: tabs())

      assert html =~ "bg-tymeslot-100"
      assert html =~ "3"
    end

    test "renders no status dot for an :ok tab without a warning or error" do
      ok_tabs = [%{id: :calendars, label: "Calendars", count: nil, status: :ok}]
      html = render_nav(active_tab: :calendars, tabs: ok_tabs)

      refute html =~ "bg-amber-500"
      refute html =~ "bg-red-500"
    end
  end
end
