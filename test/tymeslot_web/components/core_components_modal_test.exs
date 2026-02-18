defmodule TymeslotWeb.Components.CoreComponentsModalTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias Phoenix.LiveView.JS

  alias TymeslotWeb.Components.CoreComponents.Modal

  test "modal renders click-away when shown" do
  @moduletag :utils
    assigns = %{
      id: "modal-test",
      show: true,
      on_cancel: JS.push("close")
    }

    html =
      render_component(
        fn assigns ->
          ~H"""
          <Modal.modal id={@id} show={@show} on_cancel={@on_cancel}>
            <:header>Test Header</:header>
            Test content
          </Modal.modal>
          """
        end,
        assigns
      )

    assert html =~ "phx-click-away"
  end

  test "modal omits click-away when hidden" do
    assigns = %{
      id: "modal-test",
      show: false,
      on_cancel: JS.push("close")
    }

    html =
      render_component(
        fn assigns ->
          ~H"""
          <Modal.modal id={@id} show={@show} on_cancel={@on_cancel}>
            <:header>Test Header</:header>
            Test content
          </Modal.modal>
          """
        end,
        assigns
      )

    refute html =~ "phx-click-away"
  end
end
