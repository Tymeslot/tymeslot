defmodule TymeslotWeb.Components.CoreComponentsModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component
  import Phoenix.LiveViewTest
  alias Phoenix.LiveView.JS

  alias TymeslotWeb.Components.CoreComponents.Modal

  test "modal renders click-away when shown" do
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

  test "modal exposes dialog semantics and a focus-trap hook for assistive tech" do
    assigns = %{id: "a11y-modal", show: true, on_cancel: JS.push("close")}

    html =
      render_component(
        fn assigns ->
          ~H"""
          <Modal.modal id={@id} show={@show} on_cancel={@on_cancel}>
            <:header>Confirm action</:header>
            Body
          </Modal.modal>
          """
        end,
        assigns
      )

    # Dialog role + modal semantics on the content element.
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    # The dialog is labelled by its title heading.
    assert html =~ ~s(aria-labelledby="a11y-modal-title")
    assert html =~ ~s(id="a11y-modal-title")
    # The overlay drives the JS focus trap / restore.
    assert html =~ ~s(phx-hook="ModalFocusTrap")
  end

  test "modal without a header omits aria-labelledby" do
    assigns = %{id: "headerless-modal", show: true, on_cancel: JS.push("close")}

    html =
      render_component(
        fn assigns ->
          ~H"""
          <Modal.modal id={@id} show={@show} on_cancel={@on_cancel}>
            Body only
          </Modal.modal>
          """
        end,
        assigns
      )

    assert html =~ ~s(role="dialog")
    refute html =~ "aria-labelledby"
  end

  describe "subtitle" do
    test "sits in the header under the title and describes the dialog" do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <Modal.modal id="sub-modal" show>
              <:header>Add location</:header>
              <:subtitle>A place you meet people.</:subtitle>
              Body
            </Modal.modal>
            """
          end,
          %{}
        )

      header = html |> LazyHTML.from_fragment() |> LazyHTML.query(".modal-header")

      assert header |> LazyHTML.query("#sub-modal-subtitle") |> LazyHTML.text() |> String.trim() ==
               "A place you meet people."

      assert html =~ ~s(aria-describedby="sub-modal-subtitle")
    end

    test "is left out, with no aria-describedby, when not given" do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <Modal.modal id="plain-modal" show>
              <:header>Add location</:header>
              Body
            </Modal.modal>
            """
          end,
          %{}
        )

      refute html =~ "plain-modal-subtitle"
      refute html =~ "aria-describedby"
    end
  end
end
