defmodule TymeslotWeb.Components.CoreComponentsEmptyStateTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.CoreComponents.Feedback

  defp render_empty_state(assigns) do
    assigns
    |> Enum.into(%{
      icon: "hero-map-pin",
      description: nil,
      size: :md,
      variant: :card,
      tone: :neutral,
      heading: :p,
      with_action: false,
      with_graphic: false,
      with_detail: false
    })
    |> then(
      &render_component(
        fn assigns ->
          ~H"""
          <CoreComponents.empty_state
            icon={@icon}
            title="No saved locations yet"
            description={@description}
            size={@size}
            variant={@variant}
            tone={@tone}
            heading={@heading}
            data-testid="the-empty-state"
          >
            <:graphic :if={@with_graphic}><svg data-role="brand-mark"></svg></:graphic>
            <:action :if={@with_action}>
              <button type="button" phx-click="new_venue">Add location</button>
            </:action>
            <p :if={@with_detail} data-role="detail">Supporting detail</p>
          </CoreComponents.empty_state>
          """
        end,
        &1
      )
    )
    |> LazyHTML.from_fragment()
  end

  defp root(doc), do: LazyHTML.query(doc, "[data-testid='the-empty-state']")
  defp class_of(node), do: node |> LazyHTML.attribute("class") |> List.first()
  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  describe "empty_state/1" do
    test "renders the title and description in the dashboard's neutral scale" do
      doc = render_empty_state(%{description: "Add an office or a studio."})

      assert LazyHTML.text(root(doc)) =~ "No saved locations yet"
      assert LazyHTML.text(root(doc)) =~ "Add an office or a studio."
      assert count(doc, "p.text-tymeslot-900") == 1
      assert count(doc, "p.text-tymeslot-500") == 1
      # The old component hardcoded white text, invisible on a white card.
      refute LazyHTML.to_html(doc) =~ "rgba(255"
    end

    test "draws a hero icon once, inside its tile, without wrapping it in a second svg" do
      doc = render_empty_state(%{})

      assert count(doc, "[aria-hidden='true'] > svg") == 1
      assert count(doc, "svg svg") == 0
    end

    test "draws a custom graphic in the tile in place of a hero icon" do
      doc = render_empty_state(%{icon: nil, with_graphic: true})

      assert count(doc, "[aria-hidden='true'] > svg[data-role='brand-mark']") == 1
      assert count(doc, "svg") == 1
    end

    test "leaves the tile out when there is neither an icon nor a graphic" do
      doc = render_empty_state(%{icon: nil})

      assert count(doc, "[aria-hidden='true']") == 0
      assert LazyHTML.text(root(doc)) =~ "No saved locations yet"
    end

    test "omits the description when none is given" do
      doc = render_empty_state(%{})

      assert count(doc, "p") == 1
    end

    test "renders the action slot, and nothing in its place when there is none" do
      with_action = render_empty_state(%{with_action: true})
      without_action = render_empty_state(%{})

      assert count(with_action, "button[phx-click='new_venue']") == 1
      assert count(without_action, "button") == 0
      assert count(without_action, "div.justify-center.gap-3") == 0
    end

    test "renders the inner block below the actions" do
      doc = render_empty_state(%{with_action: true, with_detail: true})

      assert count(doc, "[data-role='detail']") == 1
      html = LazyHTML.to_html(doc)
      {action_at, _length} = :binary.match(html, "Add location")
      {detail_at, _length} = :binary.match(html, "Supporting detail")
      assert action_at < detail_at
    end

    test "each variant draws its own surface" do
      card = doc_class(%{variant: :card})
      dashed = doc_class(%{variant: :dashed})
      plain = doc_class(%{variant: :plain})

      assert card =~ "card-glass"
      refute card =~ "border-dashed"
      assert dashed =~ "border-dashed"
      refute dashed =~ "card-glass"
      refute plain =~ "card-glass"
      refute plain =~ "border-dashed"
    end

    test "each size scales the title" do
      assert title_class(%{size: :sm}) =~ "text-token-base"
      assert title_class(%{size: :md}) =~ "text-token-lg"
      assert title_class(%{size: :lg}) =~ "text-token-2xl"
    end

    test "draws the title as a paragraph by default, or as the heading asked for" do
      assert count(render_empty_state(%{}), "p.tracking-tight") == 1

      for level <- [:h2, :h3] do
        doc = render_empty_state(%{heading: level})
        assert doc |> LazyHTML.query("#{level}") |> LazyHTML.text() =~ "No saved locations yet"
        assert count(doc, "p.tracking-tight") == 0
      end
    end

    test "each tone colours the tile and the title" do
      neutral = render_empty_state(%{})
      brand = render_empty_state(%{tone: :brand})
      warning = render_empty_state(%{tone: :warning})

      assert tile_class(neutral) =~ "bg-tymeslot-50"
      assert tile_class(neutral) =~ "text-tymeslot-400"
      assert tile_class(brand) =~ "bg-turquoise-50"
      refute tile_class(brand) =~ "bg-tymeslot-50"
      assert tile_class(warning) =~ "bg-amber-50"
      assert count(warning, "p.text-amber-700") == 1
      assert count(neutral, "p.text-tymeslot-900") == 1
    end

    test "draws only the graphic when given both a graphic and an icon" do
      doc = render_empty_state(%{with_graphic: true})

      assert count(doc, "svg") == 1
      assert count(doc, "svg[data-role='brand-mark']") == 1
    end

    test "the CoreComponents delegate declares the same attrs and slots as Feedback" do
      assert declaration(CoreComponents) == declaration(Feedback)
    end
  end

  describe "loading_card/1" do
    test "renders a spinner in a card, announced as loading" do
      doc = LazyHTML.from_fragment(render_component(&CoreComponents.loading_card/1, %{}))

      status = LazyHTML.query(doc, "[role='status']")
      assert class_of(status) =~ "card-glass"
      assert count(doc, "[role='status'] svg.spinner[aria-hidden='true']") == 1
      assert doc |> LazyHTML.query(".sr-only") |> LazyHTML.text() == "Loading"
    end

    test "announces a custom label" do
      doc =
        LazyHTML.from_fragment(
          render_component(&CoreComponents.loading_card/1, %{label: "Loading meetings"})
        )

      assert doc |> LazyHTML.query(".sr-only") |> LazyHTML.text() == "Loading meetings"
    end
  end

  defp tile_class(doc), do: doc |> LazyHTML.query("[aria-hidden='true']") |> class_of()

  defp doc_class(assigns), do: assigns |> render_empty_state() |> root() |> class_of()

  defp title_class(assigns) do
    assigns |> render_empty_state() |> LazyHTML.query("p") |> Enum.at(0) |> class_of()
  end

  defp declaration(module) do
    %{attrs: attrs, slots: slots} = module.__components__()[:empty_state]

    {Enum.map(attrs, &Map.take(&1, [:name, :type, :required, :opts])),
     Enum.map(slots, &Map.take(&1, [:name, :required]))}
  end
end
