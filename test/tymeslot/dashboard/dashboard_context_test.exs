defmodule Tymeslot.Dashboard.DashboardContextTest do
  @moduledoc """
  Tests for the DashboardContext module.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Agenda.Day
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Security.Encryption

  setup do
    user = insert(:user)
    future_start = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    {:ok, user: user, future_start: future_start}
  end

  describe "get_dashboard_data_for_action/3" do
    test "builds the agenda for the :overview action", %{user: user, future_start: future_start} do
      insert(:meeting,
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
    # Pins the full six-key default shape as well as the nil branch: every other
    # default assertion compares against `default_integration_status/0` itself,
    # so this is the only place the key set is spelled out. Keep it spelled out.
    test "returns the all-false, all-zero six-key defaults for nil user_id" do
      assert DashboardContext.get_integration_status(nil) == %{
               has_calendar: false,
               has_video: false,
               has_meeting_types: false,
               calendar_count: 0,
               video_count: 0,
               meeting_types_count: 0
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
end
