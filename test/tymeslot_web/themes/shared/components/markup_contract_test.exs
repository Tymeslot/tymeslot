defmodule TymeslotWeb.Themes.Shared.Components.MarkupContractTest do
  @moduledoc """
  The markup contract on the shared booking components
  (`docs/THEME_DEVELOPMENT_GUIDE.md`, §"The markup contract"): the attributes
  `TymeslotWeb.BookingDriver` finds a page's controls by, rendered once here
  for every theme that uses the component. A time on the week grid is a
  `slot` fact with its day and time, a time in the slot list a `time` fact
  whose value is what `select_time` sends, and the booking form the
  `attendee` fact.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Themes.Shared.Components.BookingForm
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Components.WeekGrid

  @week_start ~D[2027-03-08]

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp attr(node, name), do: node |> Floki.attribute(name) |> List.first()

  describe "WeekGrid" do
    setup do
      doc =
        (&WeekGrid.week_grid/1)
        |> render_component(%{
          week_start: @week_start,
          week_slots: %{"2027-03-08" => ["9:00 AM", "9:30 AM"], "2027-03-10" => ["2:00 PM"]},
          user_timezone: "Etc/UTC",
          booking_window_days: 30,
          target: nil
        })
        |> Floki.parse_fragment!()

      %{doc: doc}
    end

    test "marks every time as a slot fact carrying its day and its time", %{doc: doc} do
      slots =
        for node <- Floki.find(doc, "[data-fact='slot']"),
            do: {attr(node, "data-date"), attr(node, "data-time")}

      assert slots == [
               {"2027-03-08", "9:00 AM"},
               {"2027-03-08", "9:30 AM"},
               {"2027-03-10", "2:00 PM"}
             ]

      assert Floki.find(doc, "[data-testid='week-slot']:not([data-fact='slot'])") == []
    end

    test "marks the week buttons as the ways to earlier and later times", %{doc: doc} do
      assert [_prev] = Floki.find(doc, "[data-testid='week-grid-prev'][data-intent='earlier']")
      assert [_next] = Floki.find(doc, "[data-testid='week-grid-next'][data-intent='later']")
    end
  end

  describe "SlotList" do
    test "marks every time as a time fact whose value is what select_time sends" do
      doc =
        (&SlotList.slot_list/1)
        |> render_component(%{
          target: nil,
          selected_date: "2026-09-10",
          available_slots: ["9:00 AM", "9:30 AM", "1:00 PM"]
        })
        |> Floki.parse_fragment!()

      values = Floki.attribute(doc, "[data-fact='time']", "data-value")

      assert values == ["9:00 AM", "9:30 AM", "1:00 PM"]
      assert values == Floki.attribute(doc, "[data-testid='time-slot']", "phx-value-time")
    end
  end

  describe "BookingForm" do
    test "marks the booking form, and only it, as the attendee fact" do
      doc =
        (&BookingForm.booking_form/1)
        |> render_component(%{
          form: to_form(%{}, as: :booking),
          validation_errors: %{},
          target: nil
        })
        |> Floki.parse_fragment!()

      assert [form] = Floki.find(doc, "[data-fact='attendee']")
      assert attr(form, "id") == "booking-form"
      assert attr(form, "data-testid") == "booking-form"
    end
  end
end
