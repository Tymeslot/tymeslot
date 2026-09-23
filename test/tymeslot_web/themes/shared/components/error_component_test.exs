defmodule TymeslotWeb.Themes.Shared.Components.ErrorComponentTest do
  @moduledoc """
  The readiness notice faces the public: every booker of an organiser who has
  not finished setting up reads it. It must carry the explanation and nothing
  that only makes sense inside the codebase.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias Floki
  alias TymeslotWeb.Themes.Shared.Components.ErrorComponent

  test "renders the message inside the shared notice card" do
    html = render_component(ErrorComponent, id: "error-component", message: "Connect a calendar.")
    doc = Floki.parse_document!(html)

    assert [_card] = Floki.find(doc, "[data-testid='readiness-notice'] .readiness-notice-card")
    assert Floki.text(doc) =~ "Connect a calendar."
  end

  test "is styled by the shared scheduling layer, not by app.css components" do
    html = render_component(ErrorComponent, id: "error-component", message: "Connect a calendar.")
    doc = Floki.parse_document!(html)

    # `.glass-morphism-card` exists only in Quill's bundle, so borrowing the
    # core's dashboard card left Rhythm rendering bare text over its video.
    assert Floki.find(doc, ".glass-morphism-card") == []
  end

  test "never surfaces an internal reason code, even when one is passed" do
    html =
      render_component(ErrorComponent,
        id: "error-component",
        message: "Connect a calendar.",
        reason: :calendar_required
      )

    text = html |> Floki.parse_document!() |> Floki.text()

    assert text =~ "Connect a calendar."
    refute text =~ "Reason code"
    refute text =~ "calendar_required"
  end
end
