defmodule Tymeslot.Bookings.DemoOrchestratorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  alias Tymeslot.Bookings.DemoOrchestrator
  import Tymeslot.Factory

  describe "submit_booking/2" do
    test "returns ok and mock meeting for valid params" do
      user = insert(:user)
      insert(:profile, user: user, full_name: "Test Organizer")

      params = %{
        meeting_params: %{
          organizer_user_id: user.id,
          duration: 30,
          date: "2026-01-10",
          time: "10:00",
          user_timezone: "America/New_York"
        },
        form_data: %{
          "name" => "John Doe",
          "email" => "john@example.com",
          "phone" => "1234567890",
          "company" => "ACME Corp",
          "message" => "Hello"
        }
      }

      assert {:ok, meeting} = DemoOrchestrator.submit_booking(params)
      assert meeting.attendee_name == "John Doe"
      assert meeting.organizer_user_id == user.id
      assert meeting.organizer_name == "Test Organizer"
      assert meeting.status == "confirmed"
      assert meeting.duration == 30
      assert meeting.attendee_email == "john@example.com"
    end

    test "returns error for invalid duration" do
      user = insert(:user)

      params = %{
        meeting_params: %{
          organizer_user_id: user.id,
          duration: -5,
          date: "2026-01-10",
          time: "10:00",
          user_timezone: "America/New_York"
        }
      }

      assert {:error, :invalid_duration} = DemoOrchestrator.submit_booking(params)
    end

    test "returns error for missing organizer" do
      params = %{
        meeting_params: %{
          organizer_user_id: 12_345,
          duration: 30,
          date: "2026-01-10",
          time: "10:00",
          user_timezone: "America/New_York"
        },
        form_data: %{
          "name" => "John Doe",
          "email" => "john@example.com"
        }
      }

      assert {:error, :organizer_not_found} = DemoOrchestrator.submit_booking(params)
    end

    test "handles different duration formats" do
      user = insert(:user)
      insert(:profile, user: user, full_name: "Test Organizer")

      base_params = %{
        meeting_params: %{
          organizer_user_id: user.id,
          date: "2026-01-10",
          time: "10:00",
          user_timezone: "America/New_York"
        },
        form_data: %{"name" => "John Doe", "email" => "john@example.com"}
      }

      # Test string duration "15min"
      params = put_in(base_params, [:meeting_params, :duration], "15min")
      assert {:ok, meeting} = DemoOrchestrator.submit_booking(params)
      assert meeting.duration == 15

      # Test string duration "45 m"
      params = put_in(base_params, [:meeting_params, :duration], "45 m")
      assert {:ok, meeting} = DemoOrchestrator.submit_booking(params)
      assert meeting.duration == 45
    end
  end
end
