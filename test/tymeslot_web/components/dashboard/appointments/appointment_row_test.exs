defmodule TymeslotWeb.Components.Dashboard.Appointments.AppointmentRowTest do
  @moduledoc """
  Covers the appointment row in each of its three shapes.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :dashboard
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Components.Dashboard.Appointments.AppointmentRow
  alias TymeslotWeb.Components.Dashboard.Appointments.OpenAttrs

  @nbsp " "

  defp entry(attrs \\ []) do
    struct!(
      %Entry{
        id: "meeting-1",
        source: :tymeslot,
        title: "Discovery call",
        day: ~D[2026-02-05],
        start_at: ~U[2026-02-05 14:30:00Z],
        end_at: ~U[2026-02-05 15:00:00Z],
        all_day?: false,
        who: "Ada Lovelace",
        location: "Room 3B",
        join_url: "https://zoom.us/j/1",
        colour: "blueberry"
      },
      attrs
    )
  end

  defp render_row(variant, entry, extra \\ %{}) do
    assigns =
      Map.merge(
        %{
          entry: entry,
          variant: variant,
          on_open: OpenAttrs.build("open_entry", %{"id" => entry.id}),
          timezone: "Etc/UTC",
          time_format: "12h"
        },
        extra
      )

    Floki.parse_fragment!(render_component(&AppointmentRow.appointment_row/1, assigns))
  end

  defp attr(doc, name), do: doc |> Floki.attribute(name) |> List.first()

  describe ":spine" do
    test "shows who, where, the source and a Join link, and opens on click" do
      doc = render_row(:spine, entry())
      text = Floki.text(doc)

      assert text =~ "Discovery call"
      assert text =~ "Ada Lovelace"
      assert text =~ "Room 3B"
      assert text =~ "Booking"
      assert [_join] = Floki.find(doc, ~s(a[href="https://zoom.us/j/1"][target="_blank"]))
      assert attr(doc, "phx-click") == "open_entry"
      assert attr(doc, "phx-value-id") == "meeting-1"
      assert attr(doc, "role") == "button"
      assert Floki.attribute(doc, "data-keyboard-click") != []
      assert attr(doc, "aria-label") == "View details for Discovery call"
    end

    test "badges a running appointment as happening now, and only then" do
      refute Floki.text(render_row(:spine, entry())) =~ "Now"
      assert Floki.text(render_row(:spine, entry(), %{live: true})) =~ "Now"
    end

    test "lifts the next appointment's card" do
      assert attr(render_row(:spine, entry(), %{highlight: true}), "class") =~
               "border-turquoise-200"

      refute attr(render_row(:spine, entry()), "class") =~ "border-turquoise-200"
    end
  end

  describe ":peek" do
    test "shows the start time, title, who and the entry's colour" do
      doc = render_row(:peek, entry())
      text = Floki.text(doc)

      assert text =~ "2:30 PM"
      assert text =~ "Discovery call"
      assert text =~ "Ada Lovelace"
      assert Floki.raw_html(doc) =~ EventColour.tailwind_class("blueberry")
      assert Floki.find(doc, "a") == []
    end

    test "says all day instead of a time for an all-day entry" do
      assert Floki.text(render_row(:peek, entry(all_day?: true))) =~ "All day"
    end
  end

  describe ":list" do
    test "is a list item led by the full time range, in the caller's colour" do
      doc = render_row(:list, entry(), %{colour_class: "bg-turquoise-600", id: "agenda-row-1"})

      assert [{"li", _attrs, _children}] = doc
      assert attr(doc, "id") == "agenda-row-1"
      assert Floki.text(doc) =~ "2:30#{@nbsp}PM#{@nbsp}– 3:00#{@nbsp}PM"
      assert Floki.text(doc) =~ "Room 3B"
      assert [_dot] = Floki.find(doc, "span.bg-turquoise-600")

      assert attr(doc, "aria-label") ==
               "Discovery call, 2:30#{@nbsp}PM#{@nbsp}– 3:00#{@nbsp}PM"
    end

    test "labels an untitled event" do
      assert Floki.text(render_row(:list, entry(title: nil))) =~ "(No title)"
    end
  end
end
