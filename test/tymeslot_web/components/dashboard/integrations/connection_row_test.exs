defmodule TymeslotWeb.Components.Dashboard.Integrations.ConnectionRowTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionRow

  defp render_row(overrides) do
    assigns =
      Map.merge(
        %{
          id: "cal-1",
          icon: "google",
          icon_type: :calendar,
          title: "Google Calendar",
          type_tag: "CalDAV",
          summary: "Syncing 2 calendars",
          status: {:ok, "Healthy"},
          active?: true,
          expanded?: false,
          toggle_event: "toggle_integration",
          expand_event: "toggle_row",
          myself: "hub"
        },
        overrides
      )

    render_component(
      fn assigns ->
        ~H"""
        <ConnectionRow.connection_row
          id={@id}
          icon={@icon}
          icon_type={@icon_type}
          title={@title}
          type_tag={@type_tag}
          summary={@summary}
          status={@status}
          active?={@active?}
          expanded?={@expanded?}
          toggle_event={@toggle_event}
          expand_event={@expand_event}
          myself={@myself}
        >
          <:header_action>Header action content</:header_action>
          <:detail>Detail slot content</:detail>
          <:actions>Actions slot content</:actions>
        </ConnectionRow.connection_row>
        """
      end,
      assigns
    )
  end

  describe "collapsed row" do
    test "renders title, type tag, summary, and status label" do
      html = render_row(%{expanded?: false})

      assert html =~ "Google Calendar"
      assert html =~ "CalDAV"
      assert html =~ "Syncing 2 calendars"
      assert html =~ "Healthy"
    end

    test "does not render detail or actions slot content" do
      html = render_row(%{expanded?: false})

      refute html =~ "Detail slot content"
      refute html =~ "Actions slot content"
    end

    test "renders header_action slot content on the collapsed row" do
      html = render_row(%{expanded?: false})

      # The header action is always visible in the collapsed header — it's how
      # a Reconnect control reaches an integration that needs attention without
      # opening the expandable detail.
      assert html =~ "Header action content"
    end

    test "omits the type tag when not given" do
      html = render_row(%{type_tag: nil})

      refute html =~ "CalDAV"
    end
  end

  describe "expanded row" do
    test "renders the detail and actions slot content" do
      html = render_row(%{expanded?: true})

      assert html =~ "Detail slot content"
      assert html =~ "Actions slot content"
    end
  end

  describe "controls" do
    test "expand button targets the expand event with the row id" do
      html = render_row(%{})

      assert html =~ ~s(phx-click="toggle_row")
      assert html =~ ~s(phx-value-id="cal-1")
    end

    test "renders the status switch toggle for the row" do
      html = render_row(%{})

      assert html =~ ~s(id="toggle-cal-1")
      assert html =~ ~s(phx-click="toggle_integration")
    end

    test "de-emphasises the row when inactive" do
      html = render_row(%{active?: false})

      assert html =~ "opacity-70"
    end
  end
end
