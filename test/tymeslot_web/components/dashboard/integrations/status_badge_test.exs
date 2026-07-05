defmodule TymeslotWeb.Components.Dashboard.Integrations.StatusBadgeTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents

  defp render_badge(assigns) do
    render_component(&UIComponents.status_badge/1, Map.new(assigns))
  end

  describe "status_badge/1" do
    test "renders an :ok variant with its label and green/emerald colour class" do
      html = render_badge(variant: :ok, label: "Healthy")

      assert html =~ "Healthy"
      assert html =~ "text-emerald-800"
      assert html =~ "bg-emerald-50"
      assert html =~ "bg-emerald-500"
    end

    test "renders a :paused variant with its label and neutral colour class" do
      html = render_badge(variant: :paused, label: "Paused")

      assert html =~ "Paused"
      assert html =~ "text-tymeslot-800"
      assert html =~ "bg-tymeslot-50"
    end

    test "renders an :error variant with its label and red colour class" do
      html = render_badge(variant: :error, label: "Restricted")

      assert html =~ "Restricted"
      assert html =~ "text-red-800"
      assert html =~ "bg-red-50"
    end

    test "renders a coloured dot marked aria-hidden" do
      html = render_badge(variant: :warning, label: "Degraded")

      assert html =~ "Degraded"
      assert html =~ "bg-amber-500"
      assert html =~ ~s(aria-hidden="true")
    end

    test "merges an extra class when provided" do
      html = render_badge(variant: :info, label: "Syncing", class: "ml-2")

      assert html =~ "Syncing"
      assert html =~ "text-sky-800"
      assert html =~ "ml-2"
    end
  end
end
