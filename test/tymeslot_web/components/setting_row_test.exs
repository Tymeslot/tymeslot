defmodule TymeslotWeb.Components.CoreComponents.SettingRowTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.SettingRow

  defp render_row(attrs) do
    assigns =
      Map.merge(
        %{control: :checkbox, checked: false, disabled: false, reason?: false},
        attrs
      )

    ~H"""
    <SettingRow.setting_row
      id="guests-toggle"
      control={@control}
      label="Let invitees add guests"
      description="Each guest is emailed a confirmation."
      checked={@checked}
      disabled={@disabled}
      on_change="toggle_allow_guests"
      target="#form"
      data-testid="guests"
    >
      <:disabled_reason :if={@reason?}>
        Connect Stripe on the <a href="/payments">Payments</a> page.
      </:disabled_reason>
    </SettingRow.setting_row>
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp attr_of(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  describe "as a checkbox" do
    test "the checkbox is named by the label alone, not by its description" do
      doc = render_row(%{})

      assert attr_of(doc, "#guests-toggle", "aria-labelledby") == ["guests-toggle-label"]

      assert LazyHTML.text(LazyHTML.query(doc, "#guests-toggle-label")) =~
               "Let invitees add guests"

      refute LazyHTML.text(LazyHTML.query(doc, "#guests-toggle-label")) =~ "emailed"
    end

    test "a label holds only phrasing content" do
      doc = render_row(%{disabled: true, reason?: true})

      assert Enum.empty?(LazyHTML.query(doc, "label div, label p, label a"))
      # The reason carries a link, so it sits beside the label, not in it.
      assert Enum.count(LazyHTML.query(doc, "#guests-toggle-reason a")) == 1
    end

    test "the label wraps a checkbox that sends the change event" do
      doc = render_row(%{checked: true})

      assert attr_of(doc, "label", "for") == ["guests-toggle"]
      assert count(doc, "label input#guests-toggle[type='checkbox'][checked]") == 1
      assert attr_of(doc, "#guests-toggle", "phx-click") == ["toggle_allow_guests"]
      assert attr_of(doc, "#guests-toggle", "phx-target") == ["#form"]
      assert attr_of(doc, "#guests-toggle", "data-testid") == ["guests"]
      assert LazyHTML.text(LazyHTML.query(doc, "label")) =~ "Let invitees add guests"
    end

    test "carries no name, so a surrounding form's params are unchanged" do
      doc = render_row(%{})

      assert count(doc, "#guests-toggle") == 1
      assert count(doc, "#guests-toggle[name]") == 0
    end

    test "is unchecked when the setting is off" do
      assert count(render_row(%{}), "#guests-toggle[checked]") == 0
    end

    test "points the checkbox at its description" do
      doc = render_row(%{})

      assert attr_of(doc, "#guests-toggle", "aria-describedby") == ["guests-toggle-description"]

      assert LazyHTML.text(LazyHTML.query(doc, "#guests-toggle-description")) =~
               "Each guest is emailed a confirmation."
    end

    test "disabled, it shows and announces the reason, at full label contrast" do
      doc = render_row(%{disabled: true, reason?: true})

      assert count(doc, "#guests-toggle[disabled]") == 1

      assert LazyHTML.text(LazyHTML.query(doc, "#guests-toggle-reason")) =~
               "Connect Stripe on the Payments page."

      assert attr_of(doc, "#guests-toggle", "aria-describedby") == [
               "guests-toggle-description guests-toggle-reason"
             ]

      # The row is not faded as a whole: the explanation has to stay readable.
      classes = LazyHTML.attribute(LazyHTML.query(doc, "label, label *"), "class")
      assert classes != []
      refute Enum.any?(classes, &(&1 =~ "opacity-"))
    end

    test "the reason is not shown while the setting can be changed" do
      doc = render_row(%{reason?: true})

      assert count(doc, "#guests-toggle-reason") == 0
      assert count(doc, "#guests-toggle[disabled]") == 0
    end
  end

  describe "as a switch" do
    test "renders a labelled switch that sends the change event" do
      doc = render_row(%{control: :switch, checked: true})

      assert attr_of(doc, "button#guests-toggle", "role") == ["switch"]
      assert attr_of(doc, "#guests-toggle", "aria-checked") == ["true"]
      assert attr_of(doc, "#guests-toggle", "phx-click") == ["toggle_allow_guests"]
      assert attr_of(doc, "#guests-toggle", "data-testid") == ["guests"]
      assert attr_of(doc, "#guests-toggle", "aria-labelledby") == ["guests-toggle-label"]
      assert attr_of(doc, "label#guests-toggle-label", "for") == ["guests-toggle"]
      assert count(doc, "input[type='checkbox']") == 0
    end

    test "reports the off state" do
      assert attr_of(render_row(%{control: :switch}), "#guests-toggle", "aria-checked") == [
               "false"
             ]
    end

    test "disabled, it disables the switch and shows the reason" do
      doc = render_row(%{control: :switch, disabled: true, reason?: true})

      assert count(doc, "button#guests-toggle[disabled]") == 1

      assert LazyHTML.text(LazyHTML.query(doc, "#guests-toggle-reason")) =~
               "Connect Stripe on the Payments page."
    end
  end
end
