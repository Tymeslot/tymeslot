defmodule TymeslotWeb.Dashboard.BookingsManagementGroupMeetingsTest do
  @moduledoc """
  LiveView coverage for group-meeting participants on the dashboard meetings
  list — the organiser-facing "N/M participants" badge and the Participants
  panel, split out from `BookingsManagementTest` to keep that module under
  the large-module line limit.
  """

  use TymeslotWeb.LiveCase, async: true
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, profile: profile}
  end

  describe "Group meetings" do
    test "shows the participant count badge and live participants only",
         %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user, max_participants: 10)

      meeting =
        insert(:meeting,
          organizer_user: user,
          organizer_email: user.email,
          meeting_type_ref: meeting_type
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
      assert html =~ "2/10 participants"
      assert html =~ "Ada Lovelace"
      assert html =~ "ada@example.com"
      assert html =~ "Grace Hopper"
      refute html =~ "Left Early"
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
