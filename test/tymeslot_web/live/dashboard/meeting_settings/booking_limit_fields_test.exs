defmodule TymeslotWeb.Dashboard.MeetingSettings.Components.BookingLimitFieldsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :meeting_types

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.MeetingSettings.Components.BookingLimitFields

  defp render_fields(attrs) do
    assigns = Map.merge(%{as: nil, day: nil, week: nil, month: nil}, attrs)

    ~H"""
    <BookingLimitFields.booking_limit_fields
      id="limits"
      labelledby="limits-heading"
      as={@as}
      day={@day}
      week={@week}
      month={@month}
      phx-change="update_booking_limits"
    />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp attr_of(doc, selector, name),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  test "renders day, week and month inputs, each with its value and label" do
    doc = render_fields(%{day: 3, week: 10, month: 40})

    assert attr_of(doc, "input", "name") ==
             ~w(max_bookings_per_day max_bookings_per_week max_bookings_per_month)

    assert attr_of(doc, "input", "value") == ~w(3 10 40)

    assert attr_of(doc, "label", "for") ==
             ~w(limits-max_bookings_per_day limits-max_bookings_per_week limits-max_bookings_per_month)

    assert doc
           |> LazyHTML.query("label")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.map(&String.trim/1) ==
             ["Per day", "Per week", "Per month"]
  end

  test "an empty cap leaves the field empty with the no-limit placeholder" do
    doc = render_fields(%{})

    assert attr_of(doc, "input[value]", "value") == []
    assert attr_of(doc, "input", "placeholder") == ["No limit", "No limit", "No limit"]
  end

  test "nests the names under a form's param key" do
    doc = render_fields(%{as: "meeting_type"})

    assert attr_of(doc, "input", "name") == [
             "meeting_type[max_bookings_per_day]",
             "meeting_type[max_bookings_per_week]",
             "meeting_type[max_bookings_per_month]"
           ]
  end

  test "bounds every input by the booking limit range and passes events to each" do
    doc = render_fields(%{})

    assert attr_of(doc, "input", "min") == ["1", "1", "1"]
    assert attr_of(doc, "input", "max") == ["500", "500", "500"]
    assert attr_of(doc, "input", "phx-change") == List.duplicate("update_booking_limits", 3)
  end

  test "is a group named by the heading above it" do
    doc = render_fields(%{})

    assert attr_of(doc, "[role='group']", "aria-labelledby") == ["limits-heading"]
  end
end
