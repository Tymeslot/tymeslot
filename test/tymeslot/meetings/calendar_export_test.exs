defmodule Tymeslot.Meetings.CalendarExportTest do
  @moduledoc """
  What the booking page's confirmation step is handed for the booker's
  calendar file (`CalendarExport.for_booker/1`).
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  alias Tymeslot.Meetings.CalendarExport

  describe "for_booker/1" do
    test "a solo booking hands over its uid" do
      meeting = insert(:meeting)

      assert CalendarExport.for_booker(meeting) == {:meeting, meeting.uid}
    end

    test "the booker is never handed the uid of an unverified booking" do
      held = insert(:awaiting_verification_meeting)

      assert CalendarExport.for_booker(held) == :none

      verified = %{held | status: :confirmed, email_verified_at: DateTime.utc_now(:second)}

      assert CalendarExport.for_booker(verified) == {:meeting, held.uid}
    end
  end
end
