defmodule Tymeslot.Bookings.SeatReleaseTest do
  @moduledoc """
  Coverage for `SeatRelease.release/1`'s three outcomes: the meeting is
  cancelled, seats remain, or the emptiness check itself could not be
  completed. The last one must be reported honestly, not folded into
  `:seats_remain` — a caller that cannot tell "definitely still populated"
  from "don't know" cannot reason about a meeting left confirmed with
  nobody on it.
  """

  # async: false — one test patches `MeetingQueries.update_meeting_status/2`
  # with :meck to force the failure `release/1`'s error branch handles.
  # `flip_to_cancelled/1` builds its own attrs internally and they are
  # always valid, so there is no way to drive that branch through the
  # public API; :meck also replaces the module globally for every process.
  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!
  setup :capture_admin_alerts

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "Etc/UTC")
    open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        is_active: true,
        max_participants: 2
      )

    meeting_params = %{
      date: Date.add(Date.utc_today(), 2),
      time: "14:00",
      duration: "30min",
      user_timezone: "Etc/UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, meeting} =
      Create.execute(meeting_params, %{"name" => "Solo", "email" => "solo@example.com"})

    # Empty the meeting directly (rather than through `CancelSeat`) so
    # `release/1` is exercised in isolation from its callers.
    [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    {:ok, _cancelled} = ParticipantQueries.cancel(participant)

    %{meeting: meeting}
  end

  test "cancels an emptied meeting", %{meeting: meeting} do
    assert {:ok, :meeting_cancelled} = SeatRelease.release(meeting)
    assert Repo.get!(MeetingSchema, meeting.id).status == "cancelled"
  end

  test "reports seats remaining without touching the meeting", %{meeting: meeting} do
    other = insert(:participant, meeting: meeting, cancelled_at: nil)

    assert {:ok, :seats_remain} = SeatRelease.release(meeting)
    assert Repo.get!(MeetingSchema, meeting.id).status == "confirmed"
    assert ParticipantQueries.count_live_for_meeting(meeting.id) == 1
    assert other.cancelled_at == nil
  end

  test "an honest error, not :seats_remain, when the status flip fails — and it alerts",
       %{meeting: meeting} do
    :meck.new(MeetingQueries, [:passthrough])

    :meck.expect(MeetingQueries, :update_meeting_status, fn _meeting, _attrs ->
      changeset =
        %MeetingSchema{}
        |> Changeset.change()
        |> Changeset.add_error(:status, "simulated failure")

      {:error, changeset}
    end)

    try do
      # Must not be reported as `:seats_remain`: that would tell the caller
      # a confirmed meeting is definitely still populated, when in truth
      # the check never completed.
      assert {:error, :release_check_failed} = SeatRelease.release(meeting)
    after
      :meck.unload(MeetingQueries)
    end

    # The transaction rolled back — status is untouched, not flipped to
    # "cancelled" and not silently left ambiguous either.
    assert Repo.get!(MeetingSchema, meeting.id).status == "confirmed"

    assert_receive {:send_alert, :group_meeting_release_failed, payload}
    assert payload.meeting_id == meeting.id
  end
end
