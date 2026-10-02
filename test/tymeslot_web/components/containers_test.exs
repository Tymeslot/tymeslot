defmodule TymeslotWeb.Components.ContainersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  alias Floki
  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Feedback

  test "section_header renders correctly" do
    assigns = %{
      icon: "hero-calendar-days",
      title: "My Availability",
      count: 5,
      saving: true
    }

    html = render_component(&Containers.section_header/1, assigns)

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

    html = render_component(&Containers.section_header/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.text(doc) =~ "My Availability"
    # The saving indicator renders the string "Saving changes..." (asserted in
    # the test above); refuting anything else can never fire.
    refute html =~ "Saving changes..."
    refute html =~ "spinner"
    assert Floki.find(doc, "span.bg-turquoise-100") == []
  end

  describe "section_header levels" do
    for {level, size} <- [
          {1, "display-sm"},
          {2, "text-token-2xl"},
          {3, "text-token-xl"},
          {4, "text-token-lg"}
        ] do
      test "level #{level} renders an h#{level} at its own size" do
        html =
          render_component(&Containers.section_header/1, %{
            title: "Heading",
            level: unquote(level)
          })

        doc = Floki.parse_fragment!(html)

        assert [{_tag, attrs, _children}] = Floki.find(doc, "h#{unquote(level)}")
        assert {"class", class} = List.keyfind(attrs, "class", 0)
        assert class =~ unquote(size)
        assert doc |> Floki.find("h1, h2, h3, h4") |> length() == 1
      end
    end

    test "renders the actions slot at the end of the row" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Containers.section_header level={2} title="Your Webhooks">
          <:actions><button id="create">Create</button></:actions>
        </Containers.section_header>
        """)

      doc = Floki.parse_fragment!(html)
      assert [_button] = Floki.find(doc, "button#create")
      assert doc |> Floki.find("h2") |> Floki.text() |> String.trim() == "Your Webhooks"
    end
  end

  test "spinner defaults to h-5 w-5 when no class is given" do
    html = render_component(&Feedback.spinner/1, %{})
    doc = Floki.parse_document!(html)

    assert [{"svg", attrs, _children}] = Floki.find(doc, "svg.spinner")
    assert {"class", class} = List.keyfind(attrs, "class", 0)
    assert class =~ "h-5"
    assert class =~ "w-5"
  end

  test "spinner honours an explicit class override" do
    html = render_component(&Feedback.spinner/1, %{class: "h-8 w-8"})
    doc = Floki.parse_document!(html)

    assert [{"svg", attrs, _children}] = Floki.find(doc, "svg.spinner")
    assert {"class", class} = List.keyfind(attrs, "class", 0)
    assert class =~ "h-8"
    assert class =~ "w-8"
    refute class =~ "h-5"
  end

  describe "icon_badge/1" do
    # Called through `~H`, not `render_component/2`: only a HEEx call site runs
    # Phoenix's attr validation, which a function capture bypasses.
    test "accepts an icon and renders it without nesting one svg inside another" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Containers.icon_badge icon="hero-check-circle" />
        """)

      refute html =~ ~r/<svg[^>]*><svg/
      assert length(String.split(html, "<svg")) == 2
      assert html =~ "text-white"
    end

    test "still draws raw svg children when no icon is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Containers.icon_badge>
          <path d="M0 0" />
        </Containers.icon_badge>
        """)

      assert html =~ "<svg"
      assert html =~ "<path"
    end
  end

  describe "detail_line" do
    defp detail_line_html(variant) do
      assigns = %{variant: variant}

      rendered_to_string(~H"""
      <Containers.detail_line variant={@variant} icon="hero-clock" label="Time" tone={:info}>
        2:30 PM
      </Containers.detail_line>
      """)
    end

    for variant <- [:default, :compact, :tile] do
      test "#{variant}: shows the icon, the label and the value" do
        doc = unquote(variant) |> detail_line_html() |> Floki.parse_fragment!()

        assert [_svg] = Floki.find(doc, "svg")
        assert doc |> Floki.find("p") |> Floki.text() |> String.trim() == "Time"
        assert Floki.text(doc) =~ "2:30 PM"
      end
    end

    test "tints the tile by tone" do
      assert detail_line_html(:tile) =~ "bg-blue-50"
    end

    test "leaves the label out when there is none" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Containers.detail_line variant={:compact} icon="hero-bell">
          Reminders
        </Containers.detail_line>
        """)

      refute html =~ ~r/<p[\s>]/
      assert html =~ "Reminders"
    end
  end
end
