defmodule TymeslotWeb.Components.CoreComponentsInputTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Forms

  defp render_input(assigns) do
    render_component(
      fn assigns ->
        ~H"""
        <Forms.input id={@id} name="user[email]" label="Email" type="text" errors={@errors} />
        """
      end,
      assigns
    )
  end

  test "an invalid field is flagged and linked to its error message for assistive tech" do
    html = render_input(%{id: "user_email", errors: [{"can't be blank", []}]})

    # The control announces its invalid state...
    assert html =~ ~s(aria-invalid="true")
    # ...and points screen readers at the error region...
    assert html =~ ~s(aria-describedby="user_email-error")
    # ...which carries the matching id.
    assert html =~ ~s(id="user_email-error")
    assert html =~ "can&#39;t be blank"
  end

  test "a valid field carries no aria-invalid or aria-describedby" do
    html = render_input(%{id: "user_email", errors: []})

    refute html =~ "aria-invalid"
    refute html =~ "aria-describedby"
  end

  test "aria-invalid is still set when the field has no id to describe" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Forms.input name="user[email]" label="Email" type="text" errors={@errors} />
          """
        end,
        %{errors: [{"is invalid", []}]}
      )

    assert html =~ ~s(aria-invalid="true")
    refute html =~ "aria-describedby"
  end
end
