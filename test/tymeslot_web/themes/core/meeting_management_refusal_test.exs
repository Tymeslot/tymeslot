defmodule TymeslotWeb.Themes.Core.MeetingManagementRefusalTest do
  @moduledoc """
  A guest confirming a cancellation from the cancel page after the meeting
  started: the page loaded while the meeting could still be cancelled, so the
  refusal arrives at the confirm, and the guest is told why in their own
  language rather than asked to try again.

  The clock has to move between loading the page and confirming, which only
  a frozen clock in this process can do, so the confirm runs the page's
  handler here.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  @moduletag :bookings

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Meetings.MeetingQueries
  alias TymeslotWeb.Themes.Core.MeetingManagement

  test "a cancel confirmed after the meeting started says why" do
    user = insert(:user)
    insert(:profile, user: user)
    start_time = DateTime.add(DateTime.utc_now(:second), 30, :minute)

    meeting =
      insert(:meeting,
        status: "confirmed",
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 60, :minute)
      )

    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    freeze_clock(DateTime.add(start_time, 5, :minute))

    socket = %Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: :cancel,
        meeting: meeting,
        client_ip: "203.0.113.#{rem(System.unique_integer([:positive]), 250)}"
      }
    }

    assert {:noreply, socket} =
             MeetingManagement.handle_meeting_event("cancel_meeting", %{}, socket)

    assert socket.assigns.flash["error"] ==
             "Ein bereits begonnener Termin kann nicht abgesagt werden"

    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
  end
end
