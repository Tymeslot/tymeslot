defmodule TymeslotWeb.Components.ConfirmationModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias Floki
  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.ConfirmationModal

  test "confirmation_modal renders correctly" do
    assigns = %{
      id: "confirm-delete",
      show: true,
      title: "Delete Item",
      message: "Are you sure you want to delete this?",
      on_cancel: %JS{},
      on_confirm: "delete_item",
      confirm_text: "Yes, Delete",
      confirm_variant: :danger
    }

    html = render_component(&ConfirmationModal.confirmation_modal/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "confirm-delete"
    assert html =~ "Delete Item"
    assert html =~ "Are you sure you want to delete this?"
    assert html =~ "Yes, Delete"
    assert Floki.find(doc, "button[phx-click='delete_item']") != []
  end

  test "confirmation_modal hides when show is false" do
    assigns = %{
      id: "confirm-delete",
      show: false,
      title: "Delete Item",
      message: "Are you sure you want to delete this?",
      on_cancel: %JS{},
      on_confirm: "delete_item"
    }

    html = render_component(&ConfirmationModal.confirmation_modal/1, assigns)
    doc = Floki.parse_document!(html)

    # Core modal uses inline style for visibility
    assert Floki.attribute(doc, "div#confirm-delete", "style") == ["display: none;"]
  end
end
