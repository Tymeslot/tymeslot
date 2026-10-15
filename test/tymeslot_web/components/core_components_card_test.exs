defmodule TymeslotWeb.Components.CoreComponentsCardTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Containers

  defp render_card(attrs) do
    assigns = Map.merge(%{title: nil, icon: nil, description: nil, actions?: false}, attrs)

    ~H"""
    <Containers.card
      id="card"
      variant={@variant}
      padding={@padding}
      interactive={@interactive}
      title={@title}
      icon={@icon}
      description={@description}
    >
      <:actions :if={@actions?}>
        <button id="card-action" type="button">Reset</button>
      </:actions>
      <p id="card-body">Body</p>
    </Containers.card>
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp defaults(extra \\ %{}),
    do: Map.merge(%{variant: :glass, padding: :md, interactive: false}, extra)

  defp classes(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> hd() |> String.split()
  end

  describe "card/1" do
    test "is a glass card at the medium padding by default, with its content" do
      doc = render_card(defaults())
      classes = classes(doc, "#card")

      assert "card-glass" in classes
      assert "p-6" in classes
      refute "card-glass--flat" in classes
      refute "card-glass--interactive" in classes
      assert LazyHTML.text(LazyHTML.query(doc, "#card #card-body")) == "Body"
    end

    test "each variant adds its own surface class" do
      assert "card-glass--flat" in classes(render_card(defaults(%{variant: :flat})), "#card")
      assert "card-glass--muted" in classes(render_card(defaults(%{variant: :muted})), "#card")
    end

    test "padding picks the spacing utility" do
      assert "p-0" in classes(render_card(defaults(%{padding: :none})), "#card")
      assert ["px-4", "py-3"] -- classes(render_card(defaults(%{padding: :xs})), "#card") == []
      assert "p-4" in classes(render_card(defaults(%{padding: :sm})), "#card")
      assert "sm:p-8" in classes(render_card(defaults(%{padding: :lg})), "#card")
    end

    test "only an interactive card carries the hover treatment" do
      assert "card-glass--interactive" in classes(
               render_card(defaults(%{interactive: true})),
               "#card"
             )
    end

    test "renders no header without a title or actions" do
      doc = render_card(defaults())

      assert Enum.empty?(LazyHTML.query(doc, "h2"))
    end

    test "a title renders an h2 heading with its icon, description and actions" do
      doc =
        render_card(
          defaults(%{
            title: "Booking limits",
            icon: "hero-clock",
            description: "Caps across every type",
            actions?: true
          })
        )

      assert LazyHTML.text(LazyHTML.query(doc, "#card h2")) =~ "Booking limits"
      assert "font-semibold" in classes(doc, "#card h2")
      assert Enum.count(LazyHTML.query(doc, "#card svg")) == 1
      assert LazyHTML.text(LazyHTML.query(doc, "#card p")) =~ "Caps across every type"
      assert Enum.count(LazyHTML.query(doc, "#card #card-action")) == 1
    end
  end

  describe "card/1 title_id" do
    test "puts the id on the title heading, so it can label a control" do
      assigns = %{}

      doc =
        ~H"""
        <Containers.card title="Booking limits" title_id="limits-heading">Body</Containers.card>
        """
        |> rendered_to_string()
        |> LazyHTML.from_fragment()

      assert LazyHTML.text(LazyHTML.query(doc, "h2#limits-heading")) =~ "Booking limits"
    end
  end

  describe "subsection_header/1" do
    defp render_header(attrs) do
      assigns = attrs

      ~H"""
      <Containers.subsection_header
        id={@id}
        title="Reminders"
        icon={@icon}
        description={@description}
        size={@size}
        level={@level}
      >
        <:actions><button id="header-action" type="button">Add</button></:actions>
      </Containers.subsection_header>
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()
    end

    defp header_defaults(extra \\ %{}),
      do: Map.merge(%{id: nil, icon: nil, description: nil, size: :md, level: 3}, extra)

    test "renders an h3 at the subsection scale by default" do
      doc = render_header(header_defaults())
      classes = classes(doc, "h3")

      assert LazyHTML.text(LazyHTML.query(doc, "h3")) =~ "Reminders"
      assert "text-token-base" in classes
      assert "font-semibold" in classes
      refute "font-black" in classes
    end

    test "level sets the tag and size :lg the card-title scale" do
      doc = render_header(header_defaults(%{level: 2, size: :lg}))

      assert Enum.empty?(LazyHTML.query(doc, "h3"))
      assert "text-token-lg" in classes(doc, "h2")
    end

    test "carries the id on the heading, so it can label a control" do
      doc = render_header(header_defaults(%{id: "limits-heading"}))

      assert LazyHTML.text(LazyHTML.query(doc, "h3#limits-heading")) =~ "Reminders"
    end

    test "renders the icon, description and actions when given" do
      doc =
        render_header(header_defaults(%{icon: "hero-bell", description: "Up to three emails"}))

      assert Enum.count(LazyHTML.query(doc, "svg")) == 1
      assert LazyHTML.text(LazyHTML.query(doc, "p")) =~ "Up to three emails"
      assert Enum.count(LazyHTML.query(doc, "#header-action")) == 1
    end

    test "renders no icon or description when not given" do
      doc = render_header(header_defaults())

      assert Enum.empty?(LazyHTML.query(doc, "svg"))
      assert Enum.empty?(LazyHTML.query(doc, "p"))
    end
  end
end
