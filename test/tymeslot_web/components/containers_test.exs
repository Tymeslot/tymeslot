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
    # The design-system `<.spinner>` carries the `spinner` class; the spin
    # animation comes from CSS (`.spinner { @apply animate-spin }`), not from a
    # utility class in the markup.
    assert html =~ "spinner"
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

  test "spinner defaults to h-5 w-5 when no class is given" do
    html = render_component(&CoreComponents.spinner/1, %{})
    doc = Floki.parse_document!(html)

    assert [{"svg", attrs, _children}] = Floki.find(doc, "svg.spinner")
    assert {"class", class} = List.keyfind(attrs, "class", 0)
    assert class =~ "h-5"
    assert class =~ "w-5"
  end

  test "spinner honours an explicit class override" do
    html = render_component(&CoreComponents.spinner/1, %{class: "h-8 w-8"})
    doc = Floki.parse_document!(html)

    assert [{"svg", attrs, _children}] = Floki.find(doc, "svg.spinner")
    assert {"class", class} = List.keyfind(attrs, "class", 0)
    assert class =~ "h-8"
    assert class =~ "w-8"
    refute class =~ "h-5"
  end
end
