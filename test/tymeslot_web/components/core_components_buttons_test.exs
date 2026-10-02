defmodule TymeslotWeb.Components.CoreComponentsButtonsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.CoreComponents.Buttons

  # Every test renders through the CoreComponents delegates rather than the
  # Buttons module, so an attribute the delegate fails to declare shows up here.
  defp render_doc(template, assigns \\ %{}) do
    template |> render_component(assigns) |> LazyHTML.from_fragment()
  end

  defp classes(doc, selector) do
    [class] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class")
    String.split(class)
  end

  defp attr_of(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  describe "action_button/1" do
    test "defaults to a primary, medium, type=button button" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.action_button>Save</CoreComponents.action_button>
          """
        end)

      assert attr_of(doc, "button", "type") == ["button"]
      assert classes(doc, "button") == ["action-button", "action-button--primary"]
      assert doc |> LazyHTML.query("button") |> LazyHTML.text() |> String.trim() == "Save"
      assert Enum.empty?(LazyHTML.query(doc, "button svg"))
    end

    test "maps each size to its modifier, with :md as the unmodified base" do
      for {size, expected} <- [sm: "action-button--sm", lg: "action-button--lg"] do
        doc =
          render_doc(
            fn assigns ->
              ~H"""
              <CoreComponents.action_button size={@size}>Go</CoreComponents.action_button>
              """
            end,
            %{size: size}
          )

        assert expected in classes(doc, "button")
      end

      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.action_button size={:md}>Go</CoreComponents.action_button>
          """
        end)

      refute Enum.any?(
               classes(doc, "button"),
               &(&1 in ["action-button--sm", "action-button--lg"])
             )
    end

    test "maps each variant to its kebab-case modifier" do
      expected = %{
        primary: "action-button--primary",
        secondary: "action-button--secondary",
        danger: "action-button--danger",
        danger_soft: "action-button--danger-soft",
        outline: "action-button--outline",
        ghost: "action-button--ghost",
        success: "action-button--success",
        on_dark: "action-button--on-dark"
      }

      for {variant, class} <- expected do
        doc =
          render_doc(
            fn assigns ->
              ~H"""
              <CoreComponents.action_button variant={@variant}>Go</CoreComponents.action_button>
              """
            end,
            %{variant: variant}
          )

        assert class in classes(doc, "button"), "#{variant} should render #{class}"
      end
    end

    test "renders a leading, decorative icon before the label" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.action_button icon="hero-plus" size={:sm}>Add</CoreComponents.action_button>
          """
        end)

      assert [svg_class] = attr_of(doc, "button > svg:first-child", "class")
      assert svg_class =~ "w-4 h-4"
      assert attr_of(doc, "button > svg", "aria-hidden") == ["true"]
    end

    test "passes type, form, disabled and global attributes through" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.action_button type="submit" form="f" disabled phx-click="go" class="w-full">
            Go
          </CoreComponents.action_button>
          """
        end)

      assert attr_of(doc, "button", "type") == ["submit"]
      assert attr_of(doc, "button", "form") == ["f"]
      assert attr_of(doc, "button", "disabled") == [""]
      assert attr_of(doc, "button", "phx-click") == ["go"]
      assert "w-full" in classes(doc, "button")
    end
  end

  describe "action_link/1" do
    test "navigate renders a live redirect link with the button look" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.action_link navigate="/dashboard" variant={:secondary} size={:sm}>
            Open
          </CoreComponents.action_link>
          """
        end)

      assert attr_of(doc, "a", "href") == ["/dashboard"]
      assert attr_of(doc, "a", "data-phx-link") == ["redirect"]

      assert classes(doc, "a") == [
               "action-button",
               "action-button--secondary",
               "action-button--sm"
             ]
    end

    test "patch renders a live patch link" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.action_link patch="/dashboard?tab=a">Tab</CoreComponents.action_link>
          """
        end)

      assert attr_of(doc, "a", "href") == ["/dashboard?tab=a"]
      assert attr_of(doc, "a", "data-phx-link") == ["patch"]
    end

    test "href renders a plain link carrying target, rel and an icon" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.action_link
            href="https://meet.example.com/x"
            target="_blank"
            rel="noopener noreferrer"
            icon="hero-video-camera-mini"
            variant={:on_dark}
          >
            Join meeting
          </CoreComponents.action_link>
          """
        end)

      assert attr_of(doc, "a", "href") == ["https://meet.example.com/x"]
      assert attr_of(doc, "a", "target") == ["_blank"]
      assert attr_of(doc, "a", "rel") == ["noopener noreferrer"]
      assert attr_of(doc, "a", "data-phx-link") == []
      assert "action-button--on-dark" in classes(doc, "a")
      assert Enum.count(LazyHTML.query(doc, "a > svg")) == 1
    end
  end

  describe "loading_button/1" do
    test "shows the label and icon when idle" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.loading_button icon="hero-check" size={:lg} variant={:success}>
            Save
          </CoreComponents.loading_button>
          """
        end)

      assert attr_of(doc, "button", "disabled") == []
      assert "action-button--lg" in classes(doc, "button")
      assert "action-button--success" in classes(doc, "button")
      assert Enum.count(LazyHTML.query(doc, "button > svg")) == 1
      assert doc |> LazyHTML.query("button") |> LazyHTML.text() |> String.trim() == "Save"
    end

    test "disables itself and swaps label and icon for the loading text" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.loading_button loading loading_text="Saving..." icon="hero-check">
            Save
          </CoreComponents.loading_button>
          """
        end)

      assert attr_of(doc, "button", "disabled") == [""]
      assert doc |> LazyHTML.query("button > span") |> LazyHTML.text() == "Saving..."
      refute doc |> LazyHTML.query("button") |> LazyHTML.text() =~ "Save\n"
      # Only the spinner remains: the leading icon gives way to it.
      assert [class] = attr_of(doc, "button > svg", "class")
      assert class =~ "spinner"
    end
  end

  describe "icon_button/1" do
    test "uses the label as accessible name and tooltip" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.icon_button icon="hero-trash" label="Remove time off" variant={:danger} />
          """
        end)

      assert attr_of(doc, "button", "aria-label") == ["Remove time off"]
      assert attr_of(doc, "button", "title") == ["Remove time off"]
      assert attr_of(doc, "button", "type") == ["button"]
      assert classes(doc, "button") == ["icon-button", "icon-button--danger", "icon-button--md"]
      assert attr_of(doc, "button > svg", "aria-hidden") == ["true"]
      assert doc |> LazyHTML.query("button") |> LazyHTML.text() |> String.trim() == ""
    end

    test "renders the size and variant modifiers and passes attributes through" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.icon_button
            icon="hero-pencil-square"
            label="Edit"
            size={:sm}
            variant={:warning}
            disabled
            phx-click="edit"
          />
          """
        end)

      assert classes(doc, "button") == ["icon-button", "icon-button--warning", "icon-button--sm"]
      assert [icon_class] = attr_of(doc, "button > svg", "class")
      assert icon_class =~ "w-4 h-4"
      assert attr_of(doc, "button", "phx-click") == ["edit"]
      assert attr_of(doc, "button", "disabled") == [""]
    end
  end

  describe "icon_button/1 tooltip" do
    test "keeps the action as the accessible name and puts the reason in the title" do
      doc =
        render_doc(fn assigns ->
          ~H"""
          <CoreComponents.icon_button
            icon="hero-clipboard"
            label="Copy link"
            tooltip="Publish the page to share its link"
            aria-disabled="true"
          />
          """
        end)

      assert attr_of(doc, "button", "aria-label") == ["Copy link"]
      assert attr_of(doc, "button", "title") == ["Publish the page to share its link"]
      assert attr_of(doc, "button", "aria-disabled") == ["true"]
      assert attr_of(doc, "button", "disabled") == []
    end
  end

  describe "button_classes/2" do
    test "gives a non-button element the look of an action button" do
      assert CoreComponents.button_classes(:secondary, :sm) == [
               "action-button",
               "action-button--secondary",
               "action-button--sm"
             ]

      assert CoreComponents.button_classes(:danger_soft) == [
               "action-button",
               "action-button--danger-soft",
               nil
             ]
    end

    test "rejects an unknown variant rather than emitting a class nothing styles" do
      assert_raise FunctionClauseError, fn -> CoreComponents.button_classes(:brand, :md) end
    end
  end

  describe "delegate declarations" do
    # A delegate that declares less than its component silently rejects the
    # difference at compile time, so every attribute and its allowed values
    # must match.
    test "each CoreComponents button delegate declares exactly its component's attributes" do
      core = CoreComponents.__components__()
      buttons = Buttons.__components__()

      for name <- [:action_button, :action_link, :loading_button, :icon_button] do
        assert summary(core[name]) == summary(buttons[name]), "#{name} delegate has drifted"
      end
    end
  end

  defp summary(%{attrs: attrs}) do
    attrs
    |> Enum.map(
      &{&1.name, &1.type, &1.required, &1.opts[:default], &1.opts[:values], &1.opts[:include]}
    )
    |> Enum.sort()
  end
end
