defmodule TymeslotWeb.Dashboard.BookingsManagementGroupMeetingsTest do
  @moduledoc """
  LiveView coverage for group-meeting participants on the dashboard meetings
  list — the organiser-facing "N/M seats taken" badge and the Participants
  panel, split out from `BookingsManagementTest` to keep that module under
  the large-module line limit.
  """

  use TymeslotWeb.LiveCase, async: true
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers

  alias Plug.Test
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, profile: profile}
  end

  describe "Group meetings" do
    test "shows the seats-taken badge and live participants only",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, max_participants: 10)

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          meeting_type_ref: meeting_type,
          capacity: 10
        )

      insert(:participant,
        meeting: meeting,
        name: "Ada Lovelace",
        email: "ada@example.com"
      )

      insert(:participant,
        meeting: meeting,
        name: "Grace Hopper",
        email: "grace@example.com"
      )

      insert(:participant,
        meeting: meeting,
        name: "Left Early",
        email: "left@example.com",
        cancelled_at: DateTime.utc_now(:second)
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      html = render(view)
      assert html =~ "2/10 seats taken"
      assert html =~ "Ada Lovelace"
      assert html =~ "ada@example.com"
      assert html =~ "Grace Hopper"
      refute html =~ "Left Early"
    end

    test "counts a booker's guests as seats, matching the public booking page",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, max_participants: 10)

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          meeting_type_ref: meeting_type,
          capacity: 10
        )

      booker = insert(:participant, meeting: meeting, name: "Ada Lovelace")
      {:ok, _guests} = Guests.create_for_participant(meeting.id, booker.id, ["plus-one@e.com"])

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      # One booker who brought a guest occupies two of the ten seats.
      assert render(view) =~ "2/10 seats taken"
    end

    test "hides the guests of a booker who gave up their seat", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, max_participants: 10)

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          meeting_type_ref: meeting_type,
          capacity: 10
        )

      stayer = insert(:participant, meeting: meeting, name: "Ada Lovelace")

      {:ok, _kept} =
        Guests.create_for_participant(meeting.id, stayer.id, ["still-coming@example.com"])

      leaver =
        insert(:participant,
          meeting: meeting,
          name: "Left Early",
          cancelled_at: DateTime.utc_now(:second)
        )

      {:ok, _gone} =
        Guests.create_for_participant(meeting.id, leaver.id, ["not-coming@example.com"])

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      html = render(view)
      assert html =~ "still-coming@example.com"
      refute html =~ "not-coming@example.com"
      assert html =~ "2/10 seats taken"
    end

    test "names the card after the meeting type and omits the empty attendee email",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, max_participants: 4, name: "Group Workshop")

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          meeting_type_ref: meeting_type,
          capacity: 4,
          # Snapshotted onto the meeting row at booking time, like `capacity`
          # — see `create_group.ex`'s `group_meeting_attrs/2`.
          title: meeting_type.name,
          attendee_name: nil,
          attendee_email: nil
        )

      insert(:participant, meeting: meeting, name: "Ada Lovelace", email: "ada@example.com")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      html = render(view)
      assert html =~ "Group Workshop"
      refute html =~ "Attendee Email"
    end

    test "renders the snapshotted capacity, not the meeting type, when the meeting type was deleted",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, max_participants: 10)

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          meeting_type_ref: meeting_type,
          capacity: 4,
          title: meeting_type.name,
          attendee_name: nil,
          attendee_email: nil
        )

      # meetings.meeting_type_id is on_delete: :nilify_all — deleting the
      # meeting type must not take the dashboard list down with it.
      Repo.delete!(meeting_type)

      insert(:participant, meeting: meeting, name: "Ada Lovelace", email: "ada@example.com")

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      html = render(view)
      assert html =~ "1/4 seats taken"
      assert html =~ meeting.title
    end

    test "solo meetings show neither badge nor participant list", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Solo Booker"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      html = render(view)
      assert html =~ "Solo Booker"
      refute html =~ "participants"
      refute html =~ "Participants"
    end
  end
end
