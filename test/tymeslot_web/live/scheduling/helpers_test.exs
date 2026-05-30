defmodule TymeslotWeb.Live.Scheduling.HelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  alias Tymeslot.Availability.Calculate
  alias TymeslotWeb.Live.Scheduling.Helpers

  defp mock_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  describe "get_week_days/4" do
    test "accepts user_timezone parameter and uses it for today detection" do
      week_start = ~D[2027-06-07]
      profile = insert(:profile, advance_booking_days: 90)
      days = Helpers.get_week_days(week_start, profile, nil, "America/New_York")
      assert length(days) == 7
      assert Enum.all?(days, &Map.has_key?(&1, :today))
    end

    test "uses availability_map for dates spanning month boundaries" do
      week_start = ~D[2027-03-29]
      profile = insert(:profile, advance_booking_days: 90)

      availability_map = %{
        "2027-03-29" => true,
        "2027-03-30" => true,
        "2027-03-31" => false,
        "2027-04-01" => true,
        "2027-04-02" => true,
        "2027-04-03" => false,
        "2027-04-04" => true
      }

      days = Helpers.get_week_days(week_start, profile, availability_map, "Etc/UTC")
      assert Enum.at(days, 0).available == true
      assert Enum.at(days, 2).available == false
      assert Enum.at(days, 3).available == true
    end
  end

  describe "display_range/2" do
    test "returns range covering 42-day calendar grid" do
      {start_date, end_date} = Helpers.display_range(2027, 6)
      assert Date.diff(end_date, start_date) + 1 == 42
    end

    test "start date is a Sunday" do
      {start_date, _end_date} = Helpers.display_range(2027, 6)
      # Date.day_of_week returns 7 for Sunday
      assert Date.day_of_week(start_date) == 7
    end

    test "matches Calculate.get_calendar_days range exactly" do
      {start_date, end_date} = Helpers.display_range(2027, 3)
      calendar_days = Calculate.get_calendar_days("Etc/UTC", 2027, 3, %{})
      assert Date.to_string(start_date) == List.first(calendar_days).date
      assert Date.to_string(end_date) == List.last(calendar_days).date
    end
  end

  describe "handle_username_resolution/2 with nil username" do
    test "preserves username_context already set on socket (private booking link)" do
      socket = mock_socket(%{username_context: "alice"})

      result = Helpers.handle_username_resolution(socket, nil)

      assert result.assigns.username_context == "alice"
    end

    test "assigns nil when username_context is not present in assigns" do
      socket = mock_socket()

      result = Helpers.handle_username_resolution(socket, nil)

      assert result.assigns.username_context == nil
    end

    test "keeps nil when username_context is already nil" do
      socket = mock_socket(%{username_context: nil})

      result = Helpers.handle_username_resolution(socket, nil)

      assert result.assigns.username_context == nil
    end
  end
end
