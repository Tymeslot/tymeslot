defmodule Tymeslot.Dashboard.DashboardContextTest do
  @moduledoc """
  Tests for the DashboardContext module.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Dashboard.DashboardContext

  setup do
    user = insert(:user)
    future_start = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    {:ok, user: user, future_start: future_start}
  end

  describe "get_dashboard_data_for_action/2" do
    test "returns 3 upcoming meetings for :overview action", %{
      user: user,
      future_start: future_start
    } do
      # Create 5 upcoming meetings
      for i <- 1..5 do
        start_time = DateTime.add(future_start, i, :hour)
        end_time = DateTime.add(start_time, 60, :minute)

        insert(:meeting,
          organizer_email: user.email,
          attendee_email: "attendee#{i}@test.com",
          start_time: start_time,
          end_time: end_time,
          status: "confirmed"
        )
      end

      result = DashboardContext.get_dashboard_data_for_action(user.email, :overview)

      assert %{upcoming_meetings: meetings} = result
      assert length(meetings) == 3
    end

    test "returns meetings sorted by start time for :overview action", %{
      user: user,
      future_start: future_start
    } do
      # Insert meetings in random order but expect them sorted
      insert(:meeting,
        organizer_email: user.email,
        start_time: DateTime.add(future_start, 3, :hour),
        end_time: DateTime.add(future_start, 4, :hour)
      )

      insert(:meeting,
        organizer_email: user.email,
        start_time: DateTime.add(future_start, 1, :hour),
        end_time: DateTime.add(future_start, 2, :hour)
      )

      insert(:meeting,
        organizer_email: user.email,
        start_time: DateTime.add(future_start, 2, :hour),
        end_time: DateTime.add(future_start, 3, :hour)
      )

      result = DashboardContext.get_dashboard_data_for_action(user.email, :overview)

      assert %{upcoming_meetings: [first, second, third]} = result
      assert DateTime.compare(first.start_time, second.start_time) == :lt
      assert DateTime.compare(second.start_time, third.start_time) == :lt
    end

    test "returns empty meetings for non-overview actions", %{user: user} do
      # Create some meetings
      insert(:future_meeting, organizer_email: user.email)

      result = DashboardContext.get_dashboard_data_for_action(user.email, :settings)

      assert result == %{upcoming_meetings: []}
    end

    test "returns empty meetings for :integrations action", %{user: user} do
      result = DashboardContext.get_dashboard_data_for_action(user.email, :integrations)

      assert result == %{upcoming_meetings: []}
    end

    test "returns empty data for nil user_email" do
      result = DashboardContext.get_dashboard_data_for_action(nil, :overview)

      assert result == %{upcoming_meetings: []}
    end

    test "returns empty data for invalid user_email" do
      result = DashboardContext.get_dashboard_data_for_action(123, :overview)

      assert result == %{upcoming_meetings: []}
    end

    test "only includes confirmed upcoming meetings for :overview", %{
      user: user,
      future_start: future_start
    } do
      # Create confirmed meeting
      insert(:meeting,
        organizer_email: user.email,
        start_time: DateTime.add(future_start, 1, :hour),
        end_time: DateTime.add(future_start, 2, :hour),
        status: "confirmed"
      )

      # Create pending meeting
      insert(:meeting,
        organizer_email: user.email,
        start_time: DateTime.add(future_start, 2, :hour),
        end_time: DateTime.add(future_start, 3, :hour),
        status: "pending"
      )

      # Create cancelled meeting
      insert(:meeting,
        organizer_email: user.email,
        start_time: DateTime.add(future_start, 3, :hour),
        end_time: DateTime.add(future_start, 4, :hour),
        status: "cancelled"
      )

      result = DashboardContext.get_dashboard_data_for_action(user.email, :overview)

      assert %{upcoming_meetings: meetings} = result
      # Should only get the confirmed meeting
      assert length(meetings) == 1
      assert hd(meetings).status == "confirmed"
    end

    test "does not include past meetings for :overview", %{user: user, future_start: future_start} do
      # Create a past meeting
      past_start = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_email: user.email,
        start_time: past_start,
        end_time: DateTime.add(past_start, 60, :minute),
        status: "completed"
      )

      # Create a future meeting
      insert(:meeting,
        organizer_email: user.email,
        start_time: future_start,
        end_time: DateTime.add(future_start, 60, :minute),
        status: "confirmed"
      )

      result = DashboardContext.get_dashboard_data_for_action(user.email, :overview)

      assert %{upcoming_meetings: meetings} = result
      # Should only get the future meeting
      assert length(meetings) == 1
      assert hd(meetings).status == "confirmed"
    end
  end
end
