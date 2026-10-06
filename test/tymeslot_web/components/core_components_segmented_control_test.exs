defmodule TymeslotWeb.Components.CoreComponentsSegmentedControlTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Navigation

  defp render_control(value, extra \\ %{}) do
    assigns = Map.merge(%{value: value, disabled: false, count: nil}, extra)

    ~H"""
    <Navigation.segmented_control
      id="range"
      value={@value}
      on_change="set_range"
      param="range"
      target="#owner"
      aria_label="Date range"
      disabled={@disabled}
    >
      <:option value="7d" label="7 days" icon="hero-clock" testid="range-week" />
      <:option value="30d" label="30 days" count={@count} attention />
      <:option value="90d" label="90 days" disabled />
    </Navigation.segmented_control>
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  defp attr_of(doc, selector, name), do: Floki.attribute(doc, selector, name)

  test "is a labelled group of toggle buttons" do
    doc = render_control("30d")

    assert attr_of(doc, "#range", "role") == ["group"]
    assert attr_of(doc, "#range", "aria-label") == ["Date range"]
    assert length(Floki.find(doc, "#range button[type='button']")) == 3
  end

  test "presses the chosen option, and only it" do
    doc = render_control("30d")

    assert attr_of(doc, "#range-30d", "aria-pressed") == ["true"]
    assert attr_of(doc, "#range-7d", "aria-pressed") == ["false"]
    assert attr_of(doc, "#range-90d", "aria-pressed") == ["false"]

    [chosen] = attr_of(doc, "#range-30d", "class")
    [other] = attr_of(doc, "#range-7d", "class")
    assert chosen =~ "bg-turquoise-600"
    refute other =~ "bg-turquoise-600"
  end

  test "matches the chosen value whether it is given as an atom or a string" do
    doc = render_control(:"7d")

    assert attr_of(doc, "#range-7d", "aria-pressed") == ["true"]
    assert attr_of(doc, "#range-30d", "aria-pressed") == ["false"]
  end

  test "pushes the change event with the value under the given parameter" do
    doc = render_control("30d")

    assert attr_of(doc, "#range-7d", "phx-click") == ["set_range"]
    assert attr_of(doc, "#range-7d", "phx-value-range") == ["7d"]
    assert attr_of(doc, "#range-7d", "phx-target") == ["#owner"]
    assert attr_of(doc, "#range-7d", "phx-value-value") == []
  end

  test "carries an option's test id and disables only the options marked so" do
    doc = render_control("30d")

    assert attr_of(doc, "#range-7d", "data-testid") == ["range-week"]
    assert attr_of(doc, "#range-90d", "disabled") != []
    assert attr_of(doc, "#range-7d", "disabled") == []
  end

  test "disables every option when the whole control is disabled" do
    doc = render_control("30d", %{disabled: true})

    assert length(Floki.find(doc, "#range button[disabled]")) == 3
  end

  test "shows a count only where one is given, amber while the option waits" do
    assert Floki.find(render_control("7d"), "#range-30d span.tabular-nums") == []

    doc = render_control("7d", %{count: 4})
    [badge] = Floki.find(doc, "#range-30d span.tabular-nums")
    assert Floki.text(badge) =~ "4"
    assert hd(Floki.attribute(badge, "class")) =~ "bg-amber-100"

    pressed = render_control("30d", %{count: 4})
    [badge] = Floki.find(pressed, "#range-30d span.tabular-nums")
    refute hd(Floki.attribute(badge, "class")) =~ "bg-amber-100"
  end

  test "hides option icons on a phone and keeps the row from wrapping" do
    doc = render_control("30d")

    [icon_class] = attr_of(doc, "#range-7d svg", "class")
    assert icon_class =~ "hidden sm:block"

    [class] = attr_of(doc, "#range", "class")
    assert class =~ "overflow-x-auto"
    assert class =~ "flex-nowrap"
    assert attr_of(doc, "#range", "phx-hook") == ["ScrollStrip"]
  end
end
