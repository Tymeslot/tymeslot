defmodule TymeslotWeb.Components.CoreComponentsInputConstraintsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  `maxlength` and its siblings are declared attributes, so `:global` never
  collects them. Without explicit forwarding they are accepted by the component
  and then silently dropped, which is worse than rejecting them: the caller
  believes the browser is enforcing a cap that was never rendered.
  """
  @moduletag :utils
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents

  describe "HTML constraint attributes" do
    test "reach the rendered text input" do
      html =
        render_component(&CoreComponents.input/1,
          name: "profile[heading]",
          value: "",
          maxlength: 60,
          minlength: 2
        )

      assert html =~ ~s(maxlength="60")
      assert html =~ ~s(minlength="2")
    end

    test "reach the rendered number input" do
      html =
        render_component(&CoreComponents.input/1,
          name: "profile[count]",
          type: "number",
          value: "",
          min: 1,
          max: 10,
          step: 1
        )

      assert html =~ ~s(min="1")
      assert html =~ ~s(max="10")
      assert html =~ ~s(step="1")
    end

    test "are absent when the caller does not set them" do
      html = render_component(&CoreComponents.input/1, name: "profile[heading]", value: "")

      refute html =~ "maxlength"
      refute html =~ "minlength"
      refute html =~ "pattern"
    end

    test "render disabled, which is not one of Phoenix's globals either" do
      html =
        render_component(&CoreComponents.input/1,
          name: "profile[heading]",
          value: "",
          disabled: true
        )

      assert html =~ "disabled"
    end

    test "leave no disabled attribute behind when the field is enabled" do
      html =
        render_component(&CoreComponents.input/1,
          name: "profile[heading]",
          value: "",
          disabled: false
        )

      refute html =~ "disabled"
    end

    test "do not displace an aria attribute the component adds for errors" do
      html =
        render_component(&CoreComponents.input/1,
          id: "heading",
          name: "profile[heading]",
          value: "",
          maxlength: 60,
          errors: ["can't be blank"]
        )

      assert html =~ ~s(maxlength="60")
      assert html =~ ~s(aria-invalid="true")
    end
  end
end
