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

  describe "number field keypad" do
    defp keypad(attrs) do
      fn assigns ->
        ~H"""
        <Forms.input id="amount" name="amount" type={@type} value="" {@attrs} />
        """
      end
      |> render_component(%{
        type: Map.get(attrs, :type, "number"),
        attrs: Map.delete(attrs, :type)
      })
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("inputmode")
    end

    test "a whole number from zero up asks for the numeric keypad" do
      assert keypad(%{min: 1, step: "1"}) == ["numeric"]
    end

    test "a fractional step asks for the decimal keypad" do
      assert keypad(%{min: "0.01", step: "0.01"}) == ["decimal"]
    end

    test "a field that can go negative asks for no keypad, so the minus key stays" do
      assert keypad(%{}) == []
      assert keypad(%{min: -10, step: "1"}) == []
    end

    test "a caller's inputmode wins" do
      assert keypad(%{min: 1, inputmode: "text"}) == ["text"]
    end

    test "only number fields get a keypad" do
      assert keypad(%{type: "text", min: 1}) == []
    end
  end

  describe "textarea rows" do
    defp render_textarea(assigns) do
      fn assigns ->
        ~H"""
        <Forms.input id="bio" name="bio" type="textarea" value="" {@attrs} />
        """
      end
      |> render_component(%{attrs: assigns})
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("textarea")
    end

    test "the caller's rows reach the textarea" do
      assert LazyHTML.attribute(render_textarea(%{rows: 7}), "rows") == ["7"]
    end

    test "the height is left to rows: no minimum height overrules a small value" do
      [class] = LazyHTML.attribute(render_textarea(%{rows: 2}), "class")

      refute class =~ "min-h-"
    end

    test "falls back to four rows when the caller passes none" do
      assert LazyHTML.attribute(render_textarea(%{}), "rows") == ["4"]
    end
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
          <Forms.input name="user[email]" type="text" errors={@errors} />
          """
        end,
        %{errors: [{"is invalid", []}]}
      )

    assert html =~ ~s(aria-invalid="true")
    refute html =~ "aria-describedby"
  end

  describe "a labelled field given only a name" do
    test "takes an id from the name that its label and error message point at" do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <Forms.input name="user[email]" label="Email" type="text" errors={@errors} />
            """
          end,
          %{errors: [{"is invalid", []}]}
        )

      assert html =~ ~s(for="user_email")
      assert html =~ ~s(id="user_email")
      assert html =~ ~s(aria-describedby="user_email-error")
      assert html =~ ~s(id="user_email-error")
    end

    test "keeps an explicit id" do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <Forms.input id="sign-in-email" name="email" label="Email" type="email" />
            """
          end,
          %{}
        )

      assert html =~ ~s(for="sign-in-email")
      assert html =~ ~s(id="sign-in-email")
    end

    test "leaves an unlabelled field without an id, so a repeated name cannot repeat one" do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <Forms.input name="events[]" type="checkbox" value="a" />
            <Forms.input name="events[]" type="checkbox" value="b" />
            """
          end,
          %{}
        )

      refute html =~ ~s( id=")
    end
  end

  describe "required" do
    # The attribute must land on the control itself, not only on the label's
    # `*`: it is what tells assistive technology the field is required.
    defp render_control(type, required) do
      render_component(
        fn assigns ->
          ~H"""
          <Forms.input
            id="field"
            name="field"
            label="Field"
            type={@type}
            required={@required}
          />
          """
        end,
        %{type: type, required: required}
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#field")
    end

    for {type, tag} <- [{"text", "input"}, {"textarea", "textarea"}] do
      test "renders on a #{type} control" do
        control = render_control(unquote(type), true)

        assert LazyHTML.tag(control) == [unquote(tag)]
        assert LazyHTML.attribute(control, "required") == [""]
      end
    end

    test "required={false} leaves no attribute on the control" do
      control = render_control("text", false)

      assert LazyHTML.tag(control) == ["input"]
      assert LazyHTML.attribute(control, "required") == []
    end
  end

  describe "radio" do
    defp render_radio(attrs) do
      html =
        render_component(
          fn assigns ->
            ~H"""
            <Forms.input type="radio" name="choice" {@attrs} />
            """
          end,
          %{attrs: attrs}
        )

      LazyHTML.from_fragment(html)
    end

    test "a checked radio renders checked with its own value and no text-field styling" do
      html = render_radio(id: "choice-full", value: "full", checked: true)
      radio = LazyHTML.query(html, "input[type=radio]")

      assert LazyHTML.attribute(radio, "checked") == [""]
      assert LazyHTML.attribute(radio, "value") == ["full"]
      refute "input" in String.split(hd(LazyHTML.attribute(radio, "class")))
    end

    test "an unchecked radio renders no checked attribute" do
      radio = LazyHTML.query(render_radio(value: "partial", checked: false), "input")

      assert LazyHTML.attribute(radio, "checked") == []
    end

    test "an unlabelled radio renders the bare control, with no wrapper or derived id" do
      html = render_radio(value: "full")

      assert Enum.empty?(LazyHTML.query(html, "div"))
      assert Enum.empty?(LazyHTML.query(html, "label"))
      assert LazyHTML.attribute(LazyHTML.query(html, "input"), "id") == []
    end

    test "a labelled radio sits inside its label, so a group sharing a name repeats no id" do
      html = render_radio(value: "full", label: "Full refund")

      assert Enum.count(LazyHTML.query(html, "label > input[type=radio]")) == 1
      assert LazyHTML.text(LazyHTML.query(html, "label")) =~ "Full refund"
      assert LazyHTML.attribute(LazyHTML.query(html, "input"), "id") == []
    end
  end

  describe "readonly" do
    defp render_readonly(readonly) do
      render_component(
        fn assigns ->
          ~H"""
          <Forms.input id="token" name="token" type="text" value="abc" readonly={@readonly} />
          """
        end,
        %{readonly: readonly}
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#token")
    end

    test "renders the attribute on the control" do
      assert LazyHTML.attribute(render_readonly(true), "readonly") == [""]
    end

    test "readonly={false} leaves no attribute on the control" do
      assert LazyHTML.attribute(render_readonly(false), "readonly") == []
    end
  end
end
