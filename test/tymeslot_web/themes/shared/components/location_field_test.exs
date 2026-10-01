defmodule TymeslotWeb.Themes.Shared.Components.LocationFieldTest do
  @moduledoc """
  The shared location picker's in-person half: the venue list, a single
  venue's detail, the arranged-after-booking note, and the stated location
  for a meeting type that asks nothing.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :scheduling

  import Phoenix.LiveViewTest

  alias Tymeslot.MeetingTypes.LocationOption
  alias TymeslotWeb.Themes.Shared.Components.LocationField

  @target %Phoenix.LiveComponent.CID{cid: 1}
  @berlin %{id: 1, name: "Berlin office", description: "Friedrichstrasse 1"}
  @munich %{id: 2, name: "Munich office", description: nil}
  @note "The address will be arranged with you after booking."

  defp in_person(id, label \\ "In person"),
    do: %LocationOption{id: id, kind: "in_person", label: label, position: 0}

  defp call_me,
    do: %LocationOption{
      id: "loc-call",
      kind: "phone",
      label: "Phone call",
      collect_from_guest: true,
      position: 1
    }

  defp field(attrs) do
    render_component(
      &LocationField.location_field/1,
      Map.merge(
        %{
          location_options: [in_person("loc-office"), call_me()],
          selected_location_id: "loc-office",
          target: @target
        },
        attrs
      )
    )
  end

  describe "location_field/1 for an in-person location" do
    test "lists two or more venues with each address, the chosen one checked" do
      doc =
        %{venue_choices: [@berlin, @munich], selected_venue_id: 2}
        |> field()
        |> Floki.parse_fragment!()

      assert Floki.attribute(doc, "[data-testid='venue-option']", "data-venue-id") == ["1", "2"]
      assert [_checked] = Floki.find(doc, "[data-venue-id='2'] input[checked]")
      assert [] = Floki.find(doc, "[data-venue-id='1'] input[checked]")
      assert Floki.text(doc) =~ "Friedrichstrasse 1"
    end

    test "states a single venue's name and address without asking" do
      doc = %{venue_choices: [@berlin]} |> field() |> Floki.parse_fragment!()

      assert [] = Floki.find(doc, "[data-testid='venue-field']")
      assert [detail] = Floki.find(doc, "[data-testid='location-detail']")
      assert Floki.text(detail) =~ "Berlin office"
      assert Floki.text(detail) =~ "Friedrichstrasse 1"
    end

    test "says the address is arranged after booking when there is no venue" do
      assert field(%{venue_choices: []}) =~ @note
    end
  end

  describe "location_field/1 for another kind of location" do
    test "shows neither venues nor the note" do
      html = field(%{selected_location_id: "loc-call", venue_choices: []})

      refute html =~ @note
      assert html =~ "We&#39;ll call you"
    end
  end

  describe "stated_location/1" do
    test "names a single in-person location and its venue" do
      html =
        render_component(&LocationField.stated_location/1,
          option: in_person("loc-office", "Our office"),
          venue_choices: [@berlin]
        )

      assert html =~ "Our office"
      assert html =~ "Berlin office"
      refute html =~ @note
    end

    test "names a single in-person location without a venue, with the note" do
      html =
        render_component(&LocationField.stated_location/1,
          option: in_person("loc-office"),
          venue_choices: []
        )

      assert html =~ "In person"
      assert html =~ @note
    end
  end
end
