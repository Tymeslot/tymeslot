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

  alias TymeslotWeb.Components.CoreComponents.Forms

  describe "HTML constraint attributes" do
    test "reach the rendered text input" do
      html =
        render_component(&Forms.input/1,
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
        render_component(&Forms.input/1,
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
      html = render_component(&Forms.input/1, name: "profile[heading]", value: "")

      refute html =~ "maxlength"
      refute html =~ "minlength"
      refute html =~ "pattern"
    end

    test "render disabled, which is not one of Phoenix's globals either" do
      html =
        render_component(&Forms.input/1,
          name: "profile[heading]",
          value: "",
          disabled: true
        )

      assert html =~ "disabled"
    end

    test "leave no disabled attribute behind when the field is enabled" do
      html =
        render_component(&Forms.input/1,
          name: "profile[heading]",
          value: "",
          disabled: false
        )

      refute html =~ "disabled"
    end

    test "render required on a text input, not only as the label's marker" do
      html =
        render_component(&Forms.input/1,
          id: "heading",
          name: "profile[heading]",
          label: "Heading",
          value: "",
          required: true
        )

      assert [_control] = html |> Floki.parse_fragment!() |> Floki.find("input#heading[required]")
    end

    test "render required on a select" do
      html =
        render_component(&Forms.input/1,
          id: "tz",
          name: "profile[tz]",
          type: "select",
          options: [{"UTC", "UTC"}],
          value: "UTC",
          required: true
        )

      assert [_control] = html |> Floki.parse_fragment!() |> Floki.find("select#tz[required]")
    end

    test "render required on a textarea" do
      html =
        render_component(&Forms.input/1,
          id: "notes",
          name: "profile[notes]",
          type: "textarea",
          value: "",
          required: true
        )

      assert [_control] =
               html |> Floki.parse_fragment!() |> Floki.find("textarea#notes[required]")
    end

    test "render required on a checkbox" do
      html =
        render_component(&Forms.input/1,
          id: "terms",
          name: "profile[terms]",
          type: "checkbox",
          value: false,
          required: true
        )

      doc = Floki.parse_fragment!(html)

      assert [_control] = Floki.find(doc, ~s(input#terms[type="checkbox"][required]))

      # The hidden companion that posts the unchecked value must not be
      # required: it is not a control anyone can fill in.
      assert [_hidden] = Floki.find(doc, ~s(input[type="hidden"][name="profile[terms]"]))
      assert [] = Floki.find(doc, ~s(input[type="hidden"][required]))
    end

    test "leave no required attribute behind when the field is optional" do
      html =
        render_component(&Forms.input/1,
          name: "profile[heading]",
          label: "Heading",
          value: "",
          required: false
        )

      refute html =~ "required"
    end

    test "do not displace an aria attribute the component adds for errors" do
      html =
        render_component(&Forms.input/1,
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
