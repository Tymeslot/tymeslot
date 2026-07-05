defmodule TymeslotWeb.Components.ContainersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias Floki
  alias TymeslotWeb.Components.CoreComponents

  test "section_header renders correctly" do
    assigns = %{
      icon: "hero-calendar-days",
      title: "My Availability",
      count: 5,
      saving: true
    }

    html = render_component(&CoreComponents.section_header/1, assigns)

    assert html =~ "My Availability"
    assert html =~ "5"
    assert html =~ "Saving changes..."
    assert html =~ "animate-spin"
  end

  test "section_header omits count badge and saving indicator when not set" do
    assigns = %{
      icon: "hero-calendar-days",
      title: "My Availability",
      count: nil,
      saving: false
    }

    html = render_component(&CoreComponents.section_header/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.text(doc) =~ "My Availability"
    refute html =~ "Saving..."
    assert Floki.find(doc, "span.bg-turquoise-100") == []
  end
end
