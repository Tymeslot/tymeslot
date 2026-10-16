defmodule TymeslotWeb.Themes.Shared.Journey.Facts.AttendeeTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Attendee

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  defp question(id), do: %{"id" => id, "type" => "short_text", "label" => id, "required" => true}

  test "is the attendee, owning every event of the booking form" do
    assert Attendee.key() == :attendee
    assert Attendee.required?(%{})

    assert Attendee.events() == [
             :validate,
             :field_blur,
             :select_location,
             :select_video_provider,
             :select_venue,
             :location_phone,
             :toggle_guests,
             :close_guests,
             :guest_input,
             :add_guest,
             :remove_guest,
             :submit
           ]
  end

  test "needs the slot, and the answers too when the meeting type has questions" do
    assert Attendee.requires(%{}) == [:slot]
    assert Attendee.requires(%{meeting_type: %{custom_fields: []}}) == [:slot]

    assert Attendee.requires(%{meeting_type: %{custom_fields: [question("company")]}}) ==
             [:slot, :answers]
  end

  test "is known once a booking was made for them" do
    assert Attendee.known?(%{meeting_uid: "abc123"})
    refute Attendee.known?(%{meeting_uid: ""})
    refute Attendee.known?(%{meeting_uid: nil})
    refute Attendee.known?(%{})
  end

  test "a field the booker left is marked touched, so its errors may show" do
    socket = socket(%{touched_fields: MapSet.new()})

    assert {:noreply, socket} = Attendee.handle(socket, :field_blur, "email")
    assert MapSet.member?(socket.assigns.touched_fields, "email")
  end

  test "the guest field opens on request" do
    assert {:noreply, socket} =
             Attendee.handle(socket(%{guests_open: false}), :toggle_guests, nil)

    assert socket.assigns.guests_open
  end

  test "next does not leave the form: only the submit does" do
    socket = socket(%{})

    assert Attendee.continue(socket) == {:stay, socket}
  end
end
