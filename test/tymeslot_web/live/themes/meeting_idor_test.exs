defmodule TymeslotWeb.Live.Themes.MeetingIdorTest do
  @moduledoc """
  Regression tests for the IDOR vulnerability on meeting cancel/reschedule routes.

  Before the fix, visiting /:username/meeting/:meeting_uid/cancel or /reschedule
  fetched the meeting by UID alone, allowing anyone who knew a UID to operate on
  another user's meeting by substituting a different username in the URL.
  """
  use TymeslotWeb.LiveCase, async: true
  @moduletag :security

  import Tymeslot.Factory

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp future_meeting(attrs) do
    start_time = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
    end_time = DateTime.add(start_time, 3600)

    insert(
      :meeting,
      Keyword.merge(
        [status: "confirmed", start_time: start_time, end_time: end_time],
        attrs
      )
    )
  end

  # ---------------------------------------------------------------------------
  # IDOR: cancel route
  # ---------------------------------------------------------------------------

  describe "cancel route — ownership enforcement" do
    test "rejects an attempt to cancel another user's meeting via their own username URL",
         %{conn: conn} do
      # Attacker owns profile_a. Victim owns meeting_b.
      attacker_user = insert(:user)
      attacker_profile = insert(:profile, user: attacker_user, username: "attacker")
      insert(:theme_customization, profile: attacker_profile, theme_id: "1")

      victim_user = insert(:user)
      victim_meeting = future_meeting(organizer_user: victim_user)

      # The attacker visits their own username URL but injects the victim's meeting UID.
      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, ~p"/#{attacker_profile.username}/meeting/#{victim_meeting.uid}/cancel")
    end

    test "allows the legitimate owner to visit their own cancel URL", %{conn: conn} do
      owner_user = insert(:user)
      owner_profile = insert(:profile, user: owner_user, username: "owner")
      insert(:theme_customization, profile: owner_profile, theme_id: "1")
      owner_meeting = future_meeting(organizer_user: owner_user)

      assert {:ok, _view, _html} =
               live(conn, ~p"/#{owner_profile.username}/meeting/#{owner_meeting.uid}/cancel")
    end
  end

  # ---------------------------------------------------------------------------
  # IDOR: reschedule route
  # ---------------------------------------------------------------------------

  describe "reschedule route — ownership enforcement" do
    test "rejects an attempt to reschedule another user's meeting via their own username URL",
         %{conn: conn} do
      attacker_user = insert(:user)
      attacker_profile = insert(:profile, user: attacker_user, username: "attacker2")
      insert(:theme_customization, profile: attacker_profile, theme_id: "1")

      victim_user = insert(:user)
      victim_meeting = future_meeting(organizer_user: victim_user)

      assert {:error, {:redirect, %{to: "/"}}} =
               live(
                 conn,
                 ~p"/#{attacker_profile.username}/meeting/#{victim_meeting.uid}/reschedule"
               )
    end

    test "allows the legitimate owner to visit their own reschedule URL", %{conn: conn} do
      owner_user = insert(:user)
      owner_profile = insert(:profile, user: owner_user, username: "owner2")
      insert(:theme_customization, profile: owner_profile, theme_id: "1")
      owner_meeting = future_meeting(organizer_user: owner_user)

      assert {:ok, _view, _html} =
               live(
                 conn,
                 ~p"/#{owner_profile.username}/meeting/#{owner_meeting.uid}/reschedule"
               )
    end
  end
end
