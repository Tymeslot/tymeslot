defmodule TymeslotWeb.Components.CoreComponentsPillTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.CoreComponents.Feedback

  @pill_attrs [:tone, :size, :icon, :dot, :pulse, :class]

  defp render_pill(opts) do
    {attrs, rest} = Map.split(opts, @pill_attrs)

    attrs
    |> Enum.into(%{tone: :neutral, size: :xs, icon: nil, dot: false, pulse: false, class: nil})
    |> Map.put(:rest, rest)
    |> then(
      &render_component(
        fn assigns ->
          ~H"""
          <CoreComponents.pill
            tone={@tone}
            size={@size}
            icon={@icon}
            dot={@dot}
            pulse={@pulse}
            class={@class}
            {@rest}
          >
            Label
          </CoreComponents.pill>
          """
        end,
        &1
      )
    )
    |> LazyHTML.from_fragment()
  end

  defp pill_class(doc), do: doc |> LazyHTML.query("span") |> Enum.at(0) |> attr_of("class")

  defp attr_of(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  describe "pill/1" do
    test "renders the label in a fully rounded pill" do
      doc = render_pill(%{})

      assert LazyHTML.text(doc) =~ "Label"
      assert pill_class(doc) =~ "rounded-token-full"
    end

    test "defaults to the neutral tone" do
      assert pill_class(render_pill(%{})) =~ "bg-tymeslot-100 text-tymeslot-600"
    end

    for {tone, classes} <- [
          brand: "bg-turquoise-100 text-turquoise-700",
          success: "bg-green-100 text-green-700",
          warning: "bg-amber-100 text-amber-700",
          danger: "bg-red-100 text-red-700",
          info: "bg-blue-100 text-blue-700"
        ] do
      test "colours the #{tone} tone with #{classes}" do
        class = pill_class(render_pill(%{tone: unquote(tone)}))

        assert class =~ unquote(classes)
        refute class =~ "bg-tymeslot-100"
      end
    end

    test "renders the icon before the label and no dot" do
      doc = render_pill(%{icon: "hero-check", dot: true})

      assert [_svg] = doc |> LazyHTML.query("svg") |> Enum.to_list()
      assert doc |> LazyHTML.query("span[aria-hidden]") |> Enum.to_list() == []
    end

    test "renders a static, hidden status dot in the tone's colour" do
      doc = render_pill(%{tone: :warning, dot: true})

      assert [dot] = doc |> LazyHTML.query("span[aria-hidden='true']") |> Enum.to_list()
      assert attr_of(dot, "class") =~ "bg-amber-500"
      refute attr_of(dot, "class") =~ "animate-pulse"
    end

    test "pulse renders an animated dot without needing dot" do
      doc = render_pill(%{tone: :brand, pulse: true})

      assert [dot] = doc |> LazyHTML.query("span[aria-hidden='true']") |> Enum.to_list()
      assert attr_of(dot, "class") =~ "animate-pulse"
      assert attr_of(dot, "class") =~ "bg-turquoise-500"
    end

    test "renders no dot or icon by default" do
      doc = render_pill(%{})

      assert doc |> LazyHTML.query("span[aria-hidden]") |> Enum.to_list() == []
      assert doc |> LazyHTML.query("svg") |> Enum.to_list() == []
    end

    test "size :sm pads more than the default :xs" do
      assert pill_class(render_pill(%{})) =~ "px-2 py-0.5"
      assert pill_class(render_pill(%{size: :sm})) =~ "px-3 py-1"
    end

    test "merges layout classes and passes global attributes through" do
      doc = render_pill(%{class: "mt-1", "data-testid": "the-pill", title: "Hint"})
      [span] = doc |> LazyHTML.query("[data-testid='the-pill']") |> Enum.to_list()

      assert attr_of(span, "class") =~ "mt-1"
      assert attr_of(span, "title") == "Hint"
    end
  end

  describe "pill_dot_class/1" do
    test "matches the dot the pill draws for the same tone" do
      doc = render_pill(%{tone: :danger, dot: true})
      [dot] = doc |> LazyHTML.query("span[aria-hidden='true']") |> Enum.to_list()

      assert attr_of(dot, "class") =~ Feedback.pill_dot_class(:danger)
      assert Feedback.pill_dot_class(:danger) == "bg-red-500"
    end
  end
end
