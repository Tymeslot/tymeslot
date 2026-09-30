defmodule TymeslotWeb.Themes.Shared.BookingLocationTest do
  @moduledoc """
  The booking page's venue state: which venues the chosen location offers,
  what the booker's pick submits, and when the page states a location or
  says its address is arranged after booking. Pure functions over assigns;
  the rendered journey is in `LocationChoiceFlowTest`.
  """
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :scheduling

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.LocationOption
  alias TymeslotWeb.Themes.Shared.BookingLocation

  @berlin %{id: 1, name: "Berlin office", description: "Friedrichstrasse 1\n3rd floor"}
  @munich %{id: 2, name: "Munich office", description: nil}

  defp offices,
    do: %LocationOption{
      id: "loc-offices",
      kind: "in_person",
      label: "Our offices",
      venue_ids: [1, 2],
      position: 0
    }

  defp arranged,
    do: %LocationOption{id: "loc-arranged", kind: "in_person", label: "In person", position: 1}

  defp call_me,
    do: %LocationOption{
      id: "loc-call",
      kind: "phone",
      label: "Phone call",
      collect_from_guest: true,
      position: 2
    }

  defp assigns(overrides \\ %{}) do
    Map.merge(
      %{
        location_options: [offices(), arranged(), call_me()],
        location_video_choices: %{},
        location_venue_choices: %{"loc-offices" => [@berlin, @munich]},
        selected_location_id: "loc-offices",
        selected_video_id: nil,
        selected_venue_id: 1,
        venue_picked?: false,
        location_phone: "",
        is_rescheduling: false
      },
      overrides
    )
  end

  defp socket(overrides \\ %{}),
    do: %Socket{assigns: Map.put(assigns(overrides), :__changed__, %{})}

  describe "venue_choices/1 and venue_choice_required?/1" do
    test "are the chosen in-person location's venues, asked for when there are two or more" do
      assert BookingLocation.venue_choices(assigns()) == [@berlin, @munich]
      assert BookingLocation.venue_choice_required?(assigns())
    end

    test "are empty for a location offering no venue" do
      without_venue = assigns(%{selected_location_id: "loc-arranged"})

      assert BookingLocation.venue_choices(without_venue) == []
      refute BookingLocation.venue_choice_required?(without_venue)
    end
  end

  describe "choice_required?/1" do
    test "asks for a single in-person location offering two venues" do
      assert BookingLocation.choice_required?(assigns(%{location_options: [offices()]}))
    end

    test "asks nothing for a single in-person location with one venue" do
      refute BookingLocation.choice_required?(
               assigns(%{
                 location_options: [offices()],
                 location_venue_choices: %{"loc-offices" => [@berlin]}
               })
             )
    end
  end

  describe "apply_event/3 with :select_venue" do
    test "records a venue the chosen location offers" do
      assert BookingLocation.apply_event(socket(), :select_venue, "2").assigns.selected_venue_id ==
               2
    end

    test "ignores a venue the chosen location does not offer" do
      socket = BookingLocation.apply_event(socket(), :select_venue, "99")

      assert socket.assigns.selected_venue_id == 1
      refute socket.assigns.venue_picked?
    end
  end

  describe "choose/2" do
    test "moving to a location without venues leaves no venue selected" do
      assert BookingLocation.choose(socket(), "loc-arranged").assigns.selected_venue_id == nil
    end
  end

  describe "submitted_venue_id/1" do
    test "is the picked venue for an in-person location offering venues" do
      assert BookingLocation.submitted_venue_id(assigns(%{selected_venue_id: 2})) == 2
    end

    test "is the picker's default on a new booking the booker left alone" do
      assert BookingLocation.submitted_venue_id(assigns()) == 1
    end

    test "is nil for a location without venues" do
      assert BookingLocation.submitted_venue_id(assigns(%{selected_location_id: "loc-call"})) ==
               nil
    end
  end

  describe "submitted_venue_id/1 on a reschedule" do
    test "is nil while the picker only defaulted to the location's first venue" do
      assert BookingLocation.submitted_venue_id(assigns(%{is_rescheduling: true})) == nil
    end

    test "is the venue the booker then picks, the default included" do
      picked =
        %{is_rescheduling: true}
        |> socket()
        |> BookingLocation.apply_event(:select_venue, "1")

      assert BookingLocation.submitted_venue_id(picked.assigns) == 1
    end

    test "survives a move to another location offering the same venue, and no other" do
      munich_only = %LocationOption{
        id: "loc-munich",
        kind: "in_person",
        label: "Munich",
        venue_ids: [2],
        position: 3
      }

      picked =
        %{
          is_rescheduling: true,
          location_options: [offices(), arranged(), munich_only],
          location_venue_choices: %{
            "loc-offices" => [@berlin, @munich],
            "loc-munich" => [@munich]
          }
        }
        |> socket()
        |> BookingLocation.apply_event(:select_venue, "2")

      assert BookingLocation.choose(picked, "loc-munich").assigns.venue_picked?

      back =
        picked |> BookingLocation.choose("loc-arranged") |> BookingLocation.choose("loc-offices")

      assert back.assigns.selected_venue_id == 1
      assert BookingLocation.submitted_venue_id(back.assigns) == nil
    end
  end

  describe "chosen_display/1" do
    test "is the chosen venue's one-line address" do
      assert BookingLocation.chosen_display(assigns()) ==
               "Berlin office (Friedrichstrasse 1, 3rd floor)"
    end

    test "is the label for an in-person location without a venue" do
      assert BookingLocation.chosen_display(assigns(%{selected_location_id: "loc-arranged"})) ==
               "In person"
    end

    test "is nil on a reschedule whose venue the booker did not pick, which the meeting keeps" do
      assert BookingLocation.chosen_display(assigns(%{is_rescheduling: true})) == nil
    end
  end

  describe "arranged_after_booking?/1" do
    test "is true for an in-person location without a venue" do
      assert BookingLocation.arranged_after_booking?(
               assigns(%{selected_location_id: "loc-arranged"})
             )
    end

    test "is false for a location with a venue, and for other kinds" do
      refute BookingLocation.arranged_after_booking?(assigns())
      refute BookingLocation.arranged_after_booking?(assigns(%{selected_location_id: "loc-call"}))
    end

    test "is false on a reschedule that asked nothing, which keeps the meeting's location" do
      refute BookingLocation.arranged_after_booking?(
               assigns(%{
                 location_options: [arranged()],
                 selected_location_id: "loc-arranged",
                 location_venue_choices: %{},
                 is_rescheduling: true
               })
             )
    end
  end

  describe "stated_location?/1" do
    test "states a single in-person location that asks nothing" do
      assert BookingLocation.stated_location?(
               assigns(%{
                 location_options: [arranged()],
                 selected_location_id: "loc-arranged",
                 location_venue_choices: %{}
               })
             )
    end

    test "does not state it while the booker has a choice to make" do
      refute BookingLocation.stated_location?(assigns())
    end

    test "does not state a single location of another kind" do
      refute BookingLocation.stated_location?(
               assigns(%{
                 location_options: [call_me()],
                 selected_location_id: "loc-call",
                 location_venue_choices: %{}
               })
             )
    end
  end
end
