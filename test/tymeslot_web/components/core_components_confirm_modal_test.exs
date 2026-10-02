defmodule TymeslotWeb.Components.CoreComponentsConfirmModalTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  defp render_confirm(assigns, template) do
    assigns
    |> Map.put_new(:on_cancel, JS.push("close"))
    |> then(&render_component(template, &1))
    |> LazyHTML.from_fragment()
  end

  defp texts(doc, selector) do
    doc |> LazyHTML.query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  defp attrs(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  describe "confirm_modal/1" do
    test "renders the title, body, and a Cancel then Confirm footer" do
      doc =
        render_confirm(%{}, fn assigns ->
          ~H"""
          <CoreComponents.confirm_modal
            id="c"
            show
            title="Delete thing"
            confirm_label="Delete it"
            on_cancel={@on_cancel}
            on_confirm={JS.push("delete")}
          >
            <p>Delete the thing?</p>
          </CoreComponents.confirm_modal>
          """
        end)

      assert texts(doc, "#c-title") == ["Delete thing"]
      assert texts(doc, ".modal-body p") == ["Delete the thing?"]
      assert texts(doc, ".modal-footer button") == ["Cancel", "Delete it"]
      assert [confirm_js] = attrs(doc, ".modal-footer button.action-button--danger", "phx-click")
      assert confirm_js =~ ~s("event":"delete")

      assert [cancel_js] =
               attrs(doc, ".modal-footer button.action-button--secondary", "phx-click")

      assert cancel_js =~ "close"
    end

    test "danger uses the warning triangle in a red tile, primary a turquoise one" do
      template = fn assigns ->
        ~H"""
        <CoreComponents.confirm_modal
          id="c"
          show
          title="T"
          confirm_variant={@variant}
          on_cancel={@on_cancel}
          on_confirm={JS.push("go")}
        >
          <p>Body</p>
        </CoreComponents.confirm_modal>
        """
      end

      danger = render_confirm(%{variant: :danger}, template)
      primary = render_confirm(%{variant: :primary}, template)

      assert Enum.count(LazyHTML.query(danger, "#c-title .bg-red-50 svg")) == 1
      assert Enum.count(LazyHTML.query(primary, "#c-title .bg-turquoise-50 svg")) == 1
      assert Enum.count(LazyHTML.query(primary, ".action-button--primary")) == 1
      assert Enum.empty?(LazyHTML.query(primary, ".action-button--danger"))
    end

    test "with confirm_form, Confirm submits that form instead of pushing an event" do
      doc =
        render_confirm(%{}, fn assigns ->
          ~H"""
          <CoreComponents.confirm_modal
            id="c"
            show
            title="T"
            confirm_form="the-form"
            on_cancel={@on_cancel}
          >
            <form id="the-form"></form>
          </CoreComponents.confirm_modal>
          """
        end)

      assert attrs(doc, ".action-button--danger", "type") == ["submit"]
      assert attrs(doc, ".action-button--danger", "form") == ["the-form"]
      assert attrs(doc, ".action-button--danger", "phx-click") == []
    end

    test "loading shows Confirm's spinner label and locks both buttons" do
      doc =
        render_confirm(%{}, fn assigns ->
          ~H"""
          <CoreComponents.confirm_modal
            id="c"
            show
            title="T"
            loading
            loading_label="Deleting..."
            on_cancel={@on_cancel}
            on_confirm={JS.push("go")}
          >
            <p>Body</p>
          </CoreComponents.confirm_modal>
          """
        end)

      assert texts(doc, ".action-button--danger") == ["Deleting..."]
      assert attrs(doc, ".modal-footer button", "disabled") == ["", ""]

      # Escape, a click outside and the close button push nothing while loading.
      assert [keydown] = attrs(doc, "div#c", "phx-window-keydown")
      refute keydown =~ "close"
      assert [close_js] = attrs(doc, ".modal-header button", "phx-click")
      refute close_js =~ "close"
    end

    test "undeclared attributes land on the Confirm button" do
      doc =
        render_confirm(%{}, fn assigns ->
          ~H"""
          <CoreComponents.confirm_modal
            id="c"
            show
            title="T"
            on_cancel={@on_cancel}
            on_confirm={JS.push("go")}
            phx-value-scope="series"
            data-testid="confirm-it"
          >
            <p>Body</p>
          </CoreComponents.confirm_modal>
          """
        end)

      assert attrs(doc, "[data-testid=confirm-it]", "phx-value-scope") == ["series"]
      assert attrs(doc, ".action-button--secondary", "data-testid") == []
    end

    test "the extra slot renders under the body, and actions replace Confirm" do
      doc =
        render_confirm(%{}, fn assigns ->
          ~H"""
          <CoreComponents.confirm_modal
            id="c"
            show
            title="T"
            cancel_label="Go back"
            on_cancel={@on_cancel}
          >
            <p>Body</p>
            <:extra><span id="extra">More</span></:extra>
            <:actions>
              <button type="button" id="one">One</button>
              <button type="button" id="all">All</button>
            </:actions>
          </CoreComponents.confirm_modal>
          """
        end)

      assert texts(doc, ".modal-body #extra") == ["More"]
      assert texts(doc, ".modal-footer button") == ["Go back", "One", "All"]
    end

    test "hidden when show is false" do
      doc =
        render_confirm(%{}, fn assigns ->
          ~H"""
          <CoreComponents.confirm_modal id="c" title="T" on_cancel={@on_cancel} on_confirm={JS.push("go")}>
            <p>Body</p>
          </CoreComponents.confirm_modal>
          """
        end)

      assert attrs(doc, "div#c", "style") == ["display: none;"]
    end
  end
end
