defmodule Tymeslot.Dashboard.DashboardContextTest do
  @moduledoc """
  Tests for the DashboardContext module.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Agenda.Day
  alias Tymeslot.Dashboard.DashboardContext

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

  describe "default_integration_status/0" do
    test "returns all-false, all-zero defaults" do
      result = DashboardContext.default_integration_status()

      assert result == %{
               has_calendar: false,
               has_video: false,
               has_meeting_types: false,
               calendar_count: 0,
               video_count: 0,
               meeting_types_count: 0
             }
    end
  end

  describe "get_integration_status/1" do
    test "returns defaults for nil user_id" do
      assert DashboardContext.get_integration_status(nil) ==
               DashboardContext.default_integration_status()
    end

    test "returns defaults for non-integer user_id" do
      assert DashboardContext.get_integration_status("not_an_id") ==
               DashboardContext.default_integration_status()
    end
  end
end
