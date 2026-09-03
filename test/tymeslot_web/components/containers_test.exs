defmodule TymeslotWeb.Components.ContainersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component, only: [sigil_H: 2]
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
    # The saving indicator renders the string "Saving changes..." (asserted in
    # the test above); refuting anything else can never fire.
    refute html =~ "Saving changes..."
    refute html =~ "spinner"
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

  describe "icon_badge/1 through the CoreComponents facade" do
    # The facade re-declares each delegate's attrs, and a wrapper that declares
    # fewer than its delegate silently rejects the difference: `icon` reached
    # `Containers.icon_badge/1` but `<CoreComponents.icon_badge>` would not
    # accept it, so the two entry points disagreed about what the component
    # could do. Rendering both branches through the facade pins them level.
    # Called through `~H`, not `render_component/2`: only a HEEx call site runs
    # Phoenix's attr validation, which is the thing that was broken. A function
    # capture bypasses it and would have passed against the stale declarations.
    test "accepts an icon and renders it without nesting one svg inside another" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.icon_badge icon="hero-check-circle" />
        """)

      refute html =~ ~r/<svg[^>]*><svg/
      assert length(String.split(html, "<svg")) == 2
      assert html =~ "text-white"
    end

    test "still draws raw svg children when no icon is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.icon_badge>
          <path d="M0 0" />
        </CoreComponents.icon_badge>
        """)

      assert html =~ "<svg"
      assert html =~ "<path"
    end
  end
end
