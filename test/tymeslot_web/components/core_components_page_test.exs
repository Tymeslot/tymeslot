defmodule TymeslotWeb.Components.CoreComponents.PageTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :utils

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Page

  defp render_page(saving, with_actions?) do
    assigns = %{saving: saving, with_actions?: with_actions?}

    ~H"""
    <Page.dashboard_page title="Meeting Types" icon="hero-squares-2x2" saving={@saving} id="page">
      <:actions :if={@with_actions?}><button id="page-action">Add</button></:actions>
      <section>
        <h2>Card</h2>
      </section>
    </Page.dashboard_page>
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  test "renders one h1 carrying the title, above the inner block" do
    doc = render_page(false, false)

    assert doc |> Floki.find("h1") |> Floki.text() |> String.trim() == "Meeting Types"
    assert doc |> Floki.find("#page > section h2") |> Floki.text() == "Card"
  end

  test "gives the root the shared spacing and bottom padding" do
    assert [{"div", attrs, _children}] = render_page(false, false)
    assert {"class", class} = List.keyfind(attrs, "class", 0)
    assert class =~ "space-y-8"
    assert class =~ "pb-20"
  end

  test "shows the saving indicator only while saving" do
    assert true |> render_page(false) |> Floki.find("[role=status]") |> Floki.text() =~
             "Saving changes..."

    assert Floki.find(render_page(false, false), "[role=status]") == []
  end

  test "renders header actions" do
    assert [_button] = Floki.find(render_page(false, true), "#page-action")
    assert Floki.find(render_page(false, false), "#page-action") == []
  end
end
