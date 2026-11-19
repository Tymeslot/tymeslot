defmodule TymeslotWeb.Themes.Core.MeetingManagementHoldsTest do
  @moduledoc """
  An attendee opening the manage link of a booking the organiser cannot see
  yet: one held for email verification, or one awaiting payment. The
  organiser's lookups hide both, but the attendee made them, so their cancel
  and reschedule pages find them and answer with the booking policy: a held
  booking is refused with its reason, and a booking awaiting payment can be
  cancelled as before the verification gate existed.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.Factory

  @moduletag :bookings

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Themes.Core.MeetingManagement

  setup do
    user = insert(:user)
    insert(:profile, user: user)
    %{user: user}
  end

  describe "a booking held for email verification" do
    setup %{user: user} do
      %{meeting: insert(:awaiting_verification_meeting, organizer_user_id: user.id)}
    end

    test "is hidden from the organiser's lookup", %{user: user, meeting: meeting} do
      assert Meetings.get_meeting_by_uid_for_organizer(meeting.uid, user.id) ==
               {:error, :not_found}
    end

    test "is refused with its reason on the cancel and reschedule pages", %{
      user: user,
      meeting: meeting
    } do
      assert MeetingManagement.validate_and_load_meeting(meeting.uid, :cancel, user.id) ==
               {:error, {:not_cancellable, :awaiting_verification}}

      assert MeetingManagement.validate_and_load_meeting(meeting.uid, :reschedule, user.id) ==
               {:error, {:not_reschedulable, :awaiting_verification}}

      assert Orchestrator.get_meeting_for_reschedule(meeting.uid, user.id) ==
               {:error, {:not_reschedulable, :awaiting_verification}}
    end

    test "stays not found under another organiser's page", %{meeting: meeting} do
      other = insert(:user)

      assert MeetingManagement.validate_and_load_meeting(meeting.uid, :cancel, other.id) ==
               {:error, :not_found}
    end
  end

  describe "a booking awaiting payment" do
    test "can be cancelled by its attendee", %{user: user} do
      TestMocks.setup_email_mocks()
      TestMocks.stub_no_calendar_events()
      meeting = insert(:meeting, status: :awaiting_payment, organizer_user_id: user.id)

      assert Meetings.get_meeting_by_uid_for_organizer(meeting.uid, user.id) ==
               {:error, :not_found}

      assert {:ok, %{id: id} = loaded} =
               MeetingManagement.validate_and_load_meeting(meeting.uid, :cancel, user.id)

      assert id == meeting.id

      socket = %Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          live_action: :cancel,
          meeting: loaded,
          client_ip: "203.0.113.#{rem(System.unique_integer([:positive]), 250)}"
        }
      }

      assert {:noreply, _socket} =
               MeetingManagement.handle_meeting_event("cancel_meeting", %{}, socket)

      assert {:ok, %{status: :cancelled}} = MeetingQueries.get_meeting(meeting.id)
    end
  end
end
