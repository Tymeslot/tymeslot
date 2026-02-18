defmodule TymeslotWeb.Themes.Shared.Components.ErrorComponentTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Floki
  alias TymeslotWeb.Themes.Shared.Components.ErrorComponent

  test "renders the error message without a reason code" do
  @moduletag :utils
    html = render_component(ErrorComponent, id: "error-component", message: "Connect a calendar.")
    doc = Floki.parse_document!(html)

    assert Floki.text(doc) =~ "Connect a calendar."
    refute Floki.text(doc) =~ "Reason code:"
  end

  test "renders the reason code when provided" do
    html =
      render_component(ErrorComponent,
        id: "error-component",
        message: "Connect a calendar.",
        reason: :calendar_required
      )

    doc = Floki.parse_document!(html)

    assert Floki.text(doc) =~ "Connect a calendar."
    assert Floki.text(doc) =~ "Reason code:"
    assert Floki.text(doc) =~ ":calendar_required"
  end
end
