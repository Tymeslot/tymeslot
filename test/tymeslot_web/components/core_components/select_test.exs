defmodule TymeslotWeb.Components.CoreComponents.SelectTest do
  use TymeslotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Components.CoreComponents.Select

  @moduletag :components
  @moduletag :ui

  @options [{"One", "1"}, {"Two", "2"}]

  defp render_select(attrs) do
    assigns = Keyword.merge([id: "f", name: "f", options: @options], attrs)

    LazyHTML.from_fragment(render_component(&Select.select/1, assigns))
  end

  defp value_of(doc),
    do: doc |> LazyHTML.query("input[type=hidden]") |> LazyHTML.attribute("value")

  defp text_of(doc), do: doc |> LazyHTML.query("#f-text") |> LazyHTML.text() |> String.trim()

  describe "the posted value" do
    test "travels in a hidden input named after the field" do
      doc = render_select(name: "profile[tz]", value: "2")

      assert doc |> LazyHTML.query("input[type=hidden]") |> LazyHTML.attribute("name") == [
               "profile[tz]"
             ]

      assert value_of(doc) == ["2"]
    end

    test "is left off the native select, so it is posted once" do
      assert render_select(value: "2") |> LazyHTML.query("select[name]") |> Enum.to_list() == []
    end

    test "falls back to the first option with no prompt, as a browser would" do
      assert value_of(render_select(value: "missing")) == ["1"]
    end

    test "is empty and shows the prompt when nothing is chosen" do
      doc = render_select(prompt: "Choose one")

      assert value_of(doc) == [""]
      assert text_of(doc) == "Choose one"
      assert doc |> LazyHTML.query("option[value='']") |> LazyHTML.text() == "Choose one"
    end

    test "accepts a false prompt as none" do
      assert render_select(prompt: false) |> LazyHTML.query("option[value='']") |> Enum.to_list() ==
               []
    end

    test "compares across types, as options_for_select does" do
      doc = render_select(options: [{"Ten", 10}], value: 10)

      assert value_of(doc) == ["10"]
      assert text_of(doc) == "Ten"
    end

    test "reads a label from an option group" do
      doc = render_select(options: [{"Places", [{"Hall", "h"}]}], value: "h")

      assert text_of(doc) == "Hall"

      assert doc |> LazyHTML.query("optgroup[label='Places'] option[value='h']") |> Enum.count() ==
               1
    end

    test "is disabled along with the control" do
      doc = render_select(disabled: true)

      assert doc |> LazyHTML.query("input[type=hidden][disabled]") |> Enum.count() == 1
      assert doc |> LazyHTML.query("button[disabled]") |> Enum.count() == 1
    end
  end

  describe "the listbox pattern" do
    test "the button announces a listbox it controls" do
      trigger = LazyHTML.query(render_select(label: "Field"), "#f-trigger")

      assert LazyHTML.attribute(trigger, "aria-haspopup") == ["listbox"]
      assert LazyHTML.attribute(trigger, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(trigger, "aria-controls") == ["f-panel"]
      assert LazyHTML.attribute(trigger, "aria-labelledby") == ["f-label f-text"]
    end

    test "the panel is a top-layer listbox the patch cannot touch" do
      panel = LazyHTML.query(render_select(label: "Field"), "#f-panel")

      assert LazyHTML.attribute(panel, "role") == ["listbox"]
      assert LazyHTML.attribute(panel, "popover") == ["manual"]
      assert LazyHTML.attribute(panel, "phx-update") == ["ignore"]
      assert LazyHTML.attribute(panel, "tabindex") == ["-1"]
      assert LazyHTML.attribute(panel, "aria-labelledby") == ["f-label"]
    end

    test "a label names the native control and is tied to the listbox" do
      doc = render_select(label: "Field")

      assert doc |> LazyHTML.query("label[for='f'][id='f-label']") |> Enum.count() == 1
      assert doc |> LazyHTML.query("select#f") |> Enum.count() == 1
    end

    test "an aria-label names both controls without a visible label" do
      doc = render_select(rest: %{"aria-label": "Unit"})

      assert doc |> LazyHTML.query("select[aria-label='Unit']") |> Enum.count() == 1
      assert doc |> LazyHTML.query("span#f-label[hidden]") |> LazyHTML.text() =~ "Unit"
    end

    test "a field with no name still names its button by the value alone" do
      trigger = LazyHTML.query(render_select([]), "#f-trigger")

      assert LazyHTML.attribute(trigger, "aria-labelledby") == ["f-text"]
    end

    test "errors are tied to both controls" do
      doc = render_select(errors: ["is bad"])

      assert doc
             |> LazyHTML.query("#f-trigger[aria-invalid='true'][aria-describedby='f-error']")
             |> Enum.count() == 1

      assert doc |> LazyHTML.query("select#f[aria-invalid='true']") |> Enum.count() == 1
    end

    test "a required field marks the listbox and leaves the native select unconstrained" do
      doc = render_select(label: "Field", required: true)

      assert doc |> LazyHTML.query("#f-panel[aria-required='true']") |> Enum.count() == 1
      assert doc |> LazyHTML.query("select[required]") |> Enum.to_list() == []
    end
  end

  describe "@rest" do
    test "puts phx bindings on the input that posts" do
      doc = render_select(rest: %{"phx-change": "go", "phx-target": "#x"})

      assert doc
             |> LazyHTML.query("input[type=hidden][phx-change='go'][phx-target='#x']")
             |> Enum.count() == 1

      assert doc |> LazyHTML.query("button[phx-change]") |> Enum.to_list() == []
    end

    test "puts a data attribute on the outer element" do
      doc = render_select(rest: %{"data-testid": "pick"})

      assert doc |> LazyHTML.query("#f-field[data-testid='pick'] select") |> Enum.count() == 1
    end

    test "joins an explicit describedby with the error's" do
      doc = render_select(errors: ["no"], rest: %{"aria-describedby": "hint"})

      assert doc |> LazyHTML.query("#f-trigger[aria-describedby='hint f-error']") |> Enum.count() ==
               1
    end
  end

  test "<.input type=\"select\"> raises and names the replacement" do
    assert_raise ArgumentError, ~r/use <\.select>/, fn ->
      render_component(&Forms.input/1, name: "f", type: "select")
    end
  end
end
