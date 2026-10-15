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

  test "puts the header and the inner block under one root carrying the global attributes" do
    assert [{"div", attrs, [header, body]}] = render_page(false, false)
    assert {"id", "page"} in attrs
    assert header |> Floki.find("h1") |> length() == 1
    assert {"section", _attrs, _children} = body
  end

  test "shows the saving indicator only while saving" do
    assert true |> render_page(false) |> Floki.find("[role=status]") |> Floki.text() =~
             "Saving changes..."

    # The status region stays, empty, so the indicator is announced when it appears.
    assert [status] = Floki.find(render_page(false, false), "[role=status]")
    assert Floki.text(status) == ""
  end

  test "renders header actions" do
    assert [_button] = Floki.find(render_page(false, true), "#page-action")
    assert Floki.find(render_page(false, false), "#page-action") == []
  end
end
