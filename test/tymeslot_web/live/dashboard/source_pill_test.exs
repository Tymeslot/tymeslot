defmodule TymeslotWeb.Dashboard.DashboardOverview.SourcePillTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.DashboardOverview.SourcePill

  defp render_source(source) do
    [pill] =
      render_component(&SourcePill.source_pill/1, source: source)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("span.rounded-token-full")
      |> Enum.to_list()

    {pill |> LazyHTML.text() |> String.trim(), pill |> LazyHTML.attribute("class") |> hd()}
  end

  test "a Tymeslot booking is labelled Booking in the brand colour" do
    {label, class} = render_source(:tymeslot)

    assert label == "Booking"
    assert class =~ "bg-turquoise-100"
    assert class =~ "uppercase"
  end

  test "an event from a connected calendar is labelled Calendar in neutral" do
    {label, class} = render_source(:external)

    assert label == "Calendar"
    assert class =~ "bg-tymeslot-100"
  end
end
