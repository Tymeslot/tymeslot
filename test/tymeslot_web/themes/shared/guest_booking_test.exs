defmodule TymeslotWeb.Themes.Shared.GuestBookingTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :unit

  alias Tymeslot.Meetings.Guests
  alias TymeslotWeb.Themes.Shared.GuestBooking

  defp group_assigns(seats_left, extra \\ %{}) do
    Map.merge(
      %{
        meeting_type: %Tymeslot.MeetingTypes.MeetingTypeSchema{max_participants: 10},
        selected_time: "09:00",
        available_slots: [%{time: "09:00", seats_left: seats_left, capacity: 10}]
      },
      extra
    )
  end

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
  end

  describe "seat_cap/1" do
    test "solo types keep the flat guest cap" do
      assigns = %{meeting_type: %Tymeslot.MeetingTypes.MeetingTypeSchema{max_participants: 1}}
      assert GuestBooking.seat_cap(assigns) == Guests.max_guests()
    end

    test "group types cap at seats_left minus the booker's own seat" do
      assert GuestBooking.seat_cap(group_assigns(4)) == 3
    end

    test "the flat cap still wins when plenty of seats remain" do
      assigns = %{
        meeting_type: %Tymeslot.MeetingTypes.MeetingTypeSchema{max_participants: 500},
        selected_time: "09:00",
        available_slots: [%{time: "09:00", seats_left: 400, capacity: 500}]
      }

      assert GuestBooking.seat_cap(assigns) == Guests.max_guests()
    end

    test "last seat leaves no room for guests" do
      assert GuestBooking.seat_cap(group_assigns(1)) == 0
    end

    test "falls back to the flat cap when the selected slot is unknown" do
      assert GuestBooking.seat_cap(group_assigns(4, %{selected_time: "23:45"})) ==
               Guests.max_guests()
    end
  end

  describe "assign_seat_cap/1" do
    # A booker who added guests while the slot was roomy, then lost seats to
    # other bookers, used to carry all of them into every later slot: the
    # seat transaction refuses 1 + guests over capacity, so each smaller slot
    # bounced back as "no longer available" without ever mentioning guests.
    test "drops the guests a shrunken slot has no room for" do
      socket = socket_with(group_assigns(2, %{guest_emails: ~w(a@e.com b@e.com c@e.com)}))

      assert %{assigns: assigns} = GuestBooking.assign_seat_cap(socket)
      assert assigns.max_guests == 1
      assert assigns.guest_emails == ["a@e.com"]
      assert assigns.guest_error =~ "room for 1"
    end

    test "leaves a list that still fits untouched, with no notice" do
      socket = socket_with(group_assigns(4, %{guest_emails: ~w(a@e.com b@e.com)}))

      assert %{assigns: assigns} = GuestBooking.assign_seat_cap(socket)
      assert assigns.guest_emails == ~w(a@e.com b@e.com)
      assert is_nil(assigns.guest_error)
    end

    test "clears the list entirely when only the booker fits" do
      socket = socket_with(group_assigns(1, %{guest_emails: ~w(a@e.com)}))

      assert %{assigns: assigns} = GuestBooking.assign_seat_cap(socket)
      assert assigns.max_guests == 0
      assert assigns.guest_emails == []
    end

    # A broadcast that doesn't move this booker's own cap (they're nowhere
    # near it) used to still wipe out whatever error the add form was
    # showing — e.g. "Enter a valid email address" from a bad keystroke.
    test "does not clobber an in-flight validation error when the cap is unchanged" do
      socket =
        socket_with(
          group_assigns(4, %{
            guest_emails: ~w(a@e.com b@e.com),
            max_guests: 3,
            guest_error: "Enter a valid email address."
          })
        )

      assert %{assigns: assigns} = GuestBooking.assign_seat_cap(socket)
      assert assigns.max_guests == 3
      assert assigns.guest_error == "Enter a valid email address."
    end

    test "clears a stale trim notice once the cap recovers" do
      socket =
        socket_with(
          group_assigns(4, %{
            guest_emails: [],
            max_guests: 0,
            guest_error: "This time only has room for 0 of your guests, so the rest were removed."
          })
        )

      assert %{assigns: assigns} = GuestBooking.assign_seat_cap(socket)
      assert assigns.max_guests == 3
      assert is_nil(assigns.guest_error)
    end
  end

  describe "guests_allowed?/1" do
    test "hidden when the seat cap is zero" do
      refute GuestBooking.guests_allowed?(%{
               max_guests: 0,
               meeting_type: %{allow_guests: true}
             })
    end

    test "still shown for a positive cap" do
      assert GuestBooking.guests_allowed?(%{
               max_guests: 2,
               meeting_type: %{allow_guests: true}
             })
    end

    # A visitor who had typed guests in before a seat broadcast drove the cap
    # to zero must still see the field — now capped at 0/0 — so the trim
    # notice explaining why their guests vanished stays visible. Otherwise
    # the whole field, notice included, disappears silently.
    test "still shown at a zero cap once the field was already open" do
      assert GuestBooking.guests_allowed?(%{
               max_guests: 0,
               meeting_type: %{allow_guests: true},
               guests_open: true
             })
    end
  end
end
