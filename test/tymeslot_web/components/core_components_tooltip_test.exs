defmodule TymeslotWeb.Components.CoreComponentsTooltipTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Tooltip

  defp render_doc(template, assigns \\ %{}) do
    template |> render_component(assigns) |> LazyHTML.from_fragment()
  end

  defp attr_of(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp text_of(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  describe "tooltip/1" do
    test "renders a popover bubble with role tooltip, linked through the slot" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Tooltip.tooltip :let={tip} id="why" text="Because">
            <button aria-describedby={tip}>Save</button>
          </Tooltip.tooltip>
          """
        end)

      assert attr_of(doc, "button", "aria-describedby") == ["why"]
      assert attr_of(doc, "#why", "role") == ["tooltip"]
      assert attr_of(doc, "#why", "popover") == ["manual"]
      assert text_of(doc, "#why") == "Because"
      assert attr_of(doc, "[data-tooltip] > button", "aria-describedby") == ["why"]
    end

    for empty <- [nil, "", false] do
      test "keeps the wrapper without a bubble when text is #{inspect(empty)}" do
        assigns = %{empty: unquote(empty)}

        doc =
          render_doc(
            fn assigns ->
              ~H"""
              <Tooltip.tooltip :let={tip} id="why" text={@empty}>
                <button aria-describedby={tip}>Save</button>
              </Tooltip.tooltip>
              """
            end,
            assigns
          )

        assert Enum.empty?(LazyHTML.query(doc, "[role=tooltip]"))
        assert attr_of(doc, "[data-tooltip] > button", "aria-describedby") == []
        assert doc |> LazyHTML.query("[data-tooltip] > button") |> Enum.count() == 1
      end
    end

    test "text :none renders the control with no wrapper" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Tooltip.tooltip text={:none}><button>Save</button></Tooltip.tooltip>
          """
        end)

      assert Enum.empty?(LazyHTML.query(doc, "[data-tooltip]"))
      assert doc |> LazyHTML.query("button") |> Enum.count() == 1
    end
  end

  describe "action_button/1 with a tooltip" do
    test "a disabled button keeps focusable, links its reason and does not fire" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.action_button
            id="save"
            type="submit"
            disabled
            tooltip="Finish the form first"
            phx-click="save"
          >
            Save
          </Buttons.action_button>
          """
        end)

      assert attr_of(doc, "#save", "aria-disabled") == ["true"]
      assert attr_of(doc, "#save", "disabled") == []
      assert attr_of(doc, "#save", "phx-click") == []
      assert attr_of(doc, "#save", "type") == ["button"]
      assert attr_of(doc, "#save", "aria-describedby") == ["save-tip"]
      assert text_of(doc, "#save-tip") == "Finish the form first"
    end

    test "keeps the wrapper while a tooltip's text is absent, so the button survives" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.action_button id="save" tooltip={nil}>Save</Buttons.action_button>
          """
        end)

      assert doc |> LazyHTML.query("[data-tooltip] > #save") |> Enum.count() == 1
    end

    test "has no wrapper when no tooltip attribute was given" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.action_button id="save">Save</Buttons.action_button>
          """
        end)

      assert Enum.empty?(LazyHTML.query(doc, "[data-tooltip]"))
    end

    test "disabled without a reason stays natively disabled" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.action_button id="save" disabled phx-click="save">Save</Buttons.action_button>
          """
        end)

      assert attr_of(doc, "#save", "disabled") == [""]
      assert attr_of(doc, "#save", "aria-disabled") == []
      assert attr_of(doc, "#save", "phx-click") == ["save"]
    end

    test "merges the caller's aria-describedby with the tooltip's id" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.action_button id="save" tooltip="More" aria-describedby="price">
            Save
          </Buttons.action_button>
          """
        end)

      assert attr_of(doc, "#save", "aria-describedby") == ["save-tip price"]
    end

    test "loading_button drops the tooltip while loading, so it is natively disabled" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.loading_button id="go" loading tooltip="Reason" phx-click="go">
            Go
          </Buttons.loading_button>
          """
        end)

      assert attr_of(doc, "#go", "disabled") == [""]
      assert attr_of(doc, "#go", "aria-disabled") == []
      assert Enum.empty?(LazyHTML.query(doc, "[role=tooltip]"))
      assert doc |> LazyHTML.query("[data-tooltip] > #go") |> Enum.count() == 1
    end
  end

  describe "icon_button/1" do
    test "shows its label in a tooltip without linking it, and has no title" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.icon_button icon="hero-trash" label="Delete" />
          """
        end)

      assert attr_of(doc, "button", "title") == []
      assert attr_of(doc, "button", "aria-describedby") == []
      assert text_of(doc, "[role=tooltip]") == "Delete"
    end

    test "aria-disabled drops phx-click so it cannot fire" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.icon_button
            id="copy"
            icon="hero-clipboard"
            label="Copy"
            tooltip="Publish first"
            aria-disabled="true"
            phx-click="copy"
          />
          """
        end)

      assert attr_of(doc, "#copy", "phx-click") == []
      assert attr_of(doc, "#copy", "aria-disabled") == ["true"]
      assert attr_of(doc, "#copy", "aria-describedby") == ["copy-tip"]
    end

    test "aria-disabled without a tooltip leaves the caller's click alone" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.action_button id="finish" aria-disabled="true" phx-click="finish_locked">
            Finish
          </Buttons.action_button>
          """
        end)

      assert attr_of(doc, "#finish", "phx-click") == ["finish_locked"]
      assert attr_of(doc, "#finish", "aria-disabled") == ["true"]
    end

    test "disabled with a tooltip becomes aria-disabled" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <Buttons.icon_button id="copy" icon="hero-clipboard" label="Copy" tooltip="Why" disabled />
          """
        end)

      assert attr_of(doc, "#copy", "disabled") == []
      assert attr_of(doc, "#copy", "aria-disabled") == ["true"]
    end
  end
end
