defmodule Tymeslot.Integrations.Calendar.OperationsBookingTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Integrations.Calendar.Operations

  import Tymeslot.Factory

  defp valid_event_attrs do
    start_time = DateTime.add(DateTime.utc_now(), 3600, :second)

    %{
      uid: "test-uid-#{System.unique_integer([:positive])}",
      summary: "Test Event",
      description: "Created during tests",
      start_time: start_time,
      end_time: DateTime.add(start_time, 1800, :second),
      attendee_email: "test@example.com",
      attendee_name: "Test User",
      timezone: "Etc/UTC"
    }
  end

  describe "booking integration selection" do
    test "returns default booking calendar when set" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          default_booking_calendar_id: "cal-123",
          calendar_paths: ["/dav/cal-123"],
          calendar_list: [
            %{"id" => "cal-123", "path" => "/dav/cal-123", "selected" => true}
          ]
        )

      assert {:ok, %{integration_id: id, calendar_path: "cal-123"}} =
               Operations.get_booking_integration_info(user.id)

      assert id == integration.id
    end

    test "falls back to first calendar path when no default is set" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          calendar_paths: ["/dav/fallback"]
        )

      assert {:ok, %{integration_id: id, calendar_path: "/dav/fallback"}} =
               Operations.get_booking_integration_info(user.id)

      assert id == integration.id
    end

    test "returns error when no integrations exist for user" do
      user = insert(:user)
      assert {:error, :no_integration} = Operations.get_booking_integration_info(user.id)
    end
  end

  describe "event creation safeguards" do
    test "returns error when no calendar client is available" do
      assert {:error, :no_calendar_client} = Operations.create_event(valid_event_attrs(), nil)
    end

    test "rejects invalid event payloads before hitting providers" do
      invalid_event = %{summary: "missing times"}

      assert {:error, :invalid_event_data} = Operations.create_event(invalid_event, nil)
    end
  end
end
