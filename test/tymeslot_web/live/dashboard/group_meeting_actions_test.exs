defmodule TymeslotWeb.Dashboard.GroupMeetingActionsTest do
  @moduledoc """
  The organiser cancelling a group meeting, and asking its participants for a
  new time, from the meetings dashboard.

  A group meeting has no attendee: its `attendee_*` columns are empty and its
  people are its participant rows. The modals and flashes used to name the
  attendee regardless, reading "cancel the meeting with  scheduled for..." and
  "Reschedule request sent to ". Each test also follows the action to the
  per-seat email jobs it fans out to, since the participants are who it is for.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meetings
  @moduletag :live
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)

    meeting =
      insert(:group_meeting,
        organizer_user: user,
        organizer_email: user.email,
        title: "Team Workshop",
        capacity: 4
      )

    participants =
      for name <- ["Ada", "Ben"], do: insert(:participant, meeting: meeting, name: name)

    _gone =
      insert(:participant,
        meeting: meeting,
        name: "Gone",
        cancelled_at: DateTime.utc_now(:second)
      )

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    %{
      conn: conn,
      meeting: meeting,
      participant_ids: participants |> Enum.map(& &1.id) |> Enum.sort()
    }
  end

  defp seat_job_participants(action) do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.filter(&(&1.args["action"] == action))
    |> Enum.map(& &1.args["participant_id"])
    |> Enum.sort()
  end

  test "cancelling a group meeting names its participants and emails each seat", %{
    conn: conn,
    meeting: meeting,
    participant_ids: participant_ids
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

    modal = view |> element("#cancel-meeting-form") |> render()
    assert modal =~ "cancel this group meeting with 2 participants"
    refute modal =~ "the meeting with  scheduled"
    assert render(view) =~ "Every participant will be notified of the cancellation."

    view |> form("#cancel-meeting-form") |> render_submit()

    assert render(view) =~ "Meeting cancelled successfully"
    assert Repo.get!(MeetingSchema, meeting.id).status == "cancelled"

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}
    )

    expect(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email,
                                                                                _details ->
      {:ok, nil}
    end)

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_cancellation_emails",
               "meeting_id" => meeting.id
             })

    assert seat_job_participants("send_seat_meeting_cancellation") == participant_ids
  end

  test "a reschedule request on a group meeting goes to each participant", %{
    conn: conn,
    meeting: meeting,
    participant_ids: participant_ids
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view
    |> element("[phx-click='show_reschedule_modal'][phx-value-id='#{meeting.id}']")
    |> render_click()

    modal = view |> element("#reschedule-request-modal") |> render()
    assert modal =~ "Send a reschedule request to the 2 participants of this group meeting?"
    assert modal =~ "Each participant will receive an email"

    view |> element("button", "Send Request") |> render_click()

    assert render(view) =~ "Reschedule request sent to 2 participants"
    assert %DateTime{} = Repo.get!(MeetingSchema, meeting.id).reschedule_requested_at

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
    )

    assert :ok =
             perform_job(EmailWorker, %{
               "action" => "send_reschedule_request",
               "meeting_id" => meeting.id
             })

    assert seat_job_participants("send_seat_reschedule_request") == participant_ids
  end
end
