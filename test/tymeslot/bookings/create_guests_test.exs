defmodule Tymeslot.Bookings.CreateGuestsTest do
  @moduledoc """
  Booking creation persists attendee-added guests, gated on the meeting type's
  `allow_guests` flag and re-sanitised server-side.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :bookings
  @moduletag :integration

  import Mox

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings

  import Tymeslot.AvailabilityTestHelpers

  setup do
    # The booking path asks the calendar module for the meeting type's
    # destination; these tests have no calendar integration, so stub it away.
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    :ok
  end

  defp booking_setup(meeting_type_attrs) do
    # Guests are the subject here, so the host offers every hour of every day
    # and the schedule never refuses the booking.
    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    meeting_type = insert(:meeting_type, Keyword.put(meeting_type_attrs, :user, user))

    meeting_params = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id,
      guest_emails: [
        "  Guest.One@Example.com ",
        "guest.one@example.com",
        "guest2@example.com",
        "attendee@test.com",
        "not-an-email"
      ]
    }

    form_data = %{"name" => "Test Attendee", "email" => "attendee@test.com", "message" => ""}

    %{meeting_params: meeting_params, form_data: form_data}
  end

  test "persists sanitised guests when the meeting type allows guests" do
    %{meeting_params: meeting_params, form_data: form_data} =
      booking_setup(allow_guests: true)

    assert {:ok, meeting} = Create.execute(meeting_params, form_data, skip_calendar_check: true)

    emails = meeting.id |> Meetings.list_meeting_guests() |> Enum.map(& &1.email) |> Enum.sort()

    # de-duplicated + downcased, primary attendee excluded, invalid dropped
    assert emails == ["guest.one@example.com", "guest2@example.com"]
  end

  test "stores guests as pending with an unguessable token" do
    %{meeting_params: meeting_params, form_data: form_data} =
      booking_setup(allow_guests: true)

    {:ok, meeting} = Create.execute(meeting_params, form_data, skip_calendar_check: true)
    [guest | _rest] = Meetings.list_meeting_guests(meeting.id)

    assert guest.status == "pending"
    assert byte_size(guest.rsvp_token) >= 20
  end

  test "ignores guests when the meeting type disallows them" do
    %{meeting_params: meeting_params, form_data: form_data} =
      booking_setup(allow_guests: false)

    assert {:ok, meeting} = Create.execute(meeting_params, form_data, skip_calendar_check: true)
    assert Meetings.list_meeting_guests(meeting.id) == []
  end
end
