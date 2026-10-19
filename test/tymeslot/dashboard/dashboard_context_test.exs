defmodule Tymeslot.Dashboard.DashboardContextTest do
  @moduledoc """
  Tests for the DashboardContext module.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Ecto.Changeset
  alias Tymeslot.Agenda.Day
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup do
    user = insert(:user)
    future_start = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    {:ok, user: user, future_start: future_start}
  end

  describe "get_dashboard_data_for_action/3" do
    test "builds the agenda for the :overview action", %{user: user, future_start: future_start} do
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        start_time: future_start,
        end_time: DateTime.add(future_start, 60, :minute),
        status: "confirmed",
        title: "Kickoff"
      )

      assert %{agenda: %Day{} = agenda} =
               DashboardContext.get_dashboard_data_for_action(user, "Etc/UTC", :overview)

      assert agenda.next.title == "Kickoff"
    end

    test "returns an empty map for non-overview actions", %{user: user} do
      assert DashboardContext.get_dashboard_data_for_action(user, "Etc/UTC", :settings) == %{}
      assert DashboardContext.get_dashboard_data_for_action(user, "Etc/UTC", :integrations) == %{}
    end

    test "returns an empty map for a nil user" do
      assert DashboardContext.get_dashboard_data_for_action(nil, "Etc/UTC", :overview) == %{}
    end
  end

  describe "get_integration_status/1" do
    # Pins the full default shape as well as the nil branch: every other
    # default assertion compares against `default_integration_status/0` itself,
    # so this is the only place the key set is spelled out. Keep it spelled out.
    test "returns the all-false defaults for nil user_id" do
      assert DashboardContext.get_integration_status(nil) == %{
               has_calendar: false,
               has_video: false,
               has_meeting_types: false
             }
    end

    test "returns defaults for non-integer user_id" do
      assert DashboardContext.get_integration_status("not_an_id") ==
               DashboardContext.default_integration_status()
    end

    test "reports has_calendar: false when the only integration is a read-only subscription" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
      )

      assert %{has_calendar: false} = DashboardContext.get_integration_status(user.id)
    end

    test "reports has_calendar: true when the only integration is an Exchange mailbox" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: "https://exchange.example.com/EWS/Exchange.asmx"
      )

      # `has_calendar` asks whether the account can take a booking, not whether
      # any row exists. An Exchange mailbox could not while the EWS provider
      # refused every write; it can now, so the dashboard stops telling the
      # owner to connect a calendar they have already connected.
      assert %{has_calendar: true} = DashboardContext.get_integration_status(user.id)
    end

    test "reports has_calendar: true with a CalDAV integration present" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
      )

      insert(:calendar_integration, user: user, provider: "caldav")

      assert %{has_calendar: true} = DashboardContext.get_integration_status(user.id)
    end
  end

  # The status is read fresh, so a change made outside the dashboard (another
  # tab, a background job) shows on the very next read, with nothing to
  # invalidate.
  describe "get_integration_status/1 after changes made elsewhere" do
    test "follows a meeting type being created and deleted", %{user: user} do
      refute DashboardContext.get_integration_status(user.id).has_meeting_types

      meeting_type = insert(:meeting_type, user: user, is_active: true)
      assert DashboardContext.get_integration_status(user.id).has_meeting_types

      {:ok, _deleted} = MeetingTypes.delete_meeting_type(meeting_type)
      refute DashboardContext.get_integration_status(user.id).has_meeting_types
    end

    test "counts only active meeting types", %{user: user} do
      insert(:meeting_type, user: user, is_active: false)

      refute DashboardContext.get_integration_status(user.id).has_meeting_types
    end

    test "follows a video integration being added, switched off and disconnected",
         %{user: user} do
      refute DashboardContext.get_integration_status(user.id).has_video

      integration = insert(:video_integration, user: user, is_active: true)
      assert DashboardContext.get_integration_status(user.id).has_video

      Repo.update!(Changeset.change(integration, is_active: false))
      refute DashboardContext.get_integration_status(user.id).has_video

      Repo.update!(
        Changeset.change(integration,
          is_active: true,
          deleted_at: DateTime.utc_now(:second)
        )
      )

      refute DashboardContext.get_integration_status(user.id).has_video
    end

    test "follows a CalDAV calendar being added and switched off", %{user: user} do
      refute DashboardContext.get_integration_status(user.id).has_calendar

      integration = insert(:calendar_integration, user: user, provider: "caldav")
      assert DashboardContext.get_integration_status(user.id).has_calendar

      Repo.update!(Changeset.change(integration, is_active: false))
      refute DashboardContext.get_integration_status(user.id).has_calendar
    end

    test "never counts another user's integrations or meeting types", %{user: user} do
      other = insert(:user)
      insert(:calendar_integration, user: other, provider: "caldav")
      insert(:video_integration, user: other, is_active: true)
      insert(:meeting_type, user: other, is_active: true)

      assert DashboardContext.get_integration_status(user.id) ==
               DashboardContext.default_integration_status()
    end
  end

  describe "get_integration_status/1 when the database cannot answer" do
    # A process outside the test's sandbox has no connection, which is how a
    # failing read looks from here.
    @tag :capture_log
    test "falls back to the defaults rather than raising", %{user: user} do
      parent = self()

      spawn(fn ->
        send(parent, {:status, DashboardContext.get_integration_status(user.id)})
      end)

      assert_receive {:status, status}, 5_000
      assert status == DashboardContext.default_integration_status()
    end
  end

  describe "get_meeting_settings_data/1" do
    test "lists only the user's active video integrations", %{user: user} do
      active = insert(:video_integration, user: user, is_active: true, name: "Zoom")
      insert(:video_integration, user: user, is_active: false, name: "Off")

      assert [%{id: id}] = DashboardContext.get_meeting_settings_data(user.id).video_integrations
      assert id == active.id
    end
  end
end
