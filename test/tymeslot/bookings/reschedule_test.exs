defmodule Tymeslot.Bookings.RescheduleTest do
  @moduledoc """
  Tests for the booking rescheduling module.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :bookings

  import Mox

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.ZoomOAuthHelperMock
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup do
    # Setup mocks for calendar and email services
    TestMocks.setup_email_mocks()
    :ok
  end

  defp setup_reschedule_test do
    %{user: user, profile: profile} = create_user_with_profile()
    meeting = insert_meeting_for_user(user)

    # Create new params for rescheduling (2 days from now instead of 1)
    new_date = Date.add(Date.utc_today(), 2)

    new_params = %{
      date: Date.to_string(new_date),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    %{user: user, profile: profile, meeting: meeting, new_params: new_params}
  end

  describe "execute/3 - successful rescheduling" do
    test "successfully reschedules a future meeting" do
      %{meeting: meeting, new_params: new_params} = setup_reschedule_test()

      assert {:ok, updated_meeting} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      # Verify the meeting was updated
      assert updated_meeting.id == meeting.id
      # The new start time should be different from the original
      refute DateTime.compare(updated_meeting.start_time, meeting.start_time) == :eq
    end

    test "updates meeting times correctly" do
      %{meeting: meeting, new_params: new_params} = setup_reschedule_test()

      assert {:ok, updated_meeting} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      # Reload from database to verify persistence
      {:ok, reloaded} = MeetingQueries.get_meeting_by_uid(meeting.uid)

      assert DateTime.compare(reloaded.start_time, updated_meeting.start_time) == :eq
      assert DateTime.compare(reloaded.end_time, updated_meeting.end_time) == :eq
    end
  end

  describe "execute/3 - meeting not found" do
    test "returns error when meeting does not exist" do
      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Original meeting not found"} =
               Reschedule.execute("non-existent-uid", new_params, %{}, 0)
    end
  end

  # ---------------------------------------------------------------------------
  # IDOR regression: scoped lookup prevents cross-organizer rescheduling
  # ---------------------------------------------------------------------------

  describe "execute/4 - organizer scoping (IDOR prevention)" do
    test "rejects rescheduling when organizer_user_id belongs to a different user" do
      %{user: victim_user} = create_user_with_profile()
      victim_meeting = insert_meeting_for_user(victim_user)

      attacker_user = insert(:user)
      insert(:profile, user: attacker_user)

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Original meeting not found"} =
               Reschedule.execute(victim_meeting.uid, new_params, %{}, attacker_user.id)
    end

    test "allows rescheduling when organizer_user_id matches meeting owner" do
      %{user: owner_user} = create_user_with_profile()
      owner_meeting = insert_meeting_for_user(owner_user)

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated} =
               Reschedule.execute(owner_meeting.uid, new_params, %{}, owner_user.id)

      assert updated.id == owner_meeting.id
    end
  end

  describe "execute/3 - policy violations" do
    test "returns error when meeting is already cancelled" do
      %{meeting: meeting, new_params: new_params} = setup_reschedule_test()

      # Update meeting to cancelled status
      {:ok, _meeting} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})

      assert {:error, "Cannot reschedule a cancelled meeting"} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)
    end

    test "returns error when meeting is completed" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -7_200,
          duration: 3_600
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Cannot reschedule a completed meeting"} =
               Reschedule.execute(meeting.uid, new_params, %{}, user.id)
    end

    test "returns error when meeting has already started" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -3_600,
          duration: 7_200
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Cannot reschedule a meeting that has already started"} =
               Reschedule.execute(meeting.uid, new_params, %{}, user.id)
    end

    test "returns error when meeting has already occurred" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -7_200,
          duration: 3_600
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Cannot reschedule a meeting that has already occurred"} =
               Reschedule.execute(meeting.uid, new_params, %{}, user.id)
    end
  end

  describe "execute/3 - validation errors" do
    test "returns error with invalid date format" do
      %{meeting: meeting} = setup_reschedule_test()

      invalid_params = %{
        date: "not-a-date",
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Invalid date or time format"} =
               Reschedule.execute(meeting.uid, invalid_params, %{}, meeting.organizer_user_id)
    end

    test "returns error with invalid time format" do
      %{meeting: meeting} = setup_reschedule_test()

      invalid_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "invalid-time",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:error, "Invalid date or time format"} =
               Reschedule.execute(meeting.uid, invalid_params, %{}, meeting.organizer_user_id)
    end

    test "returns error when rescheduling to a past date" do
      %{meeting: meeting} = setup_reschedule_test()

      past_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), -1)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      # Should fail with some form of time validation error
      assert {:error, _reason} =
               Reschedule.execute(meeting.uid, past_params, %{}, meeting.organizer_user_id)
    end
  end

  describe "execute/3 - edge cases" do
    test "allows rescheduling meeting that starts soon" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 600,
          duration: 3_600
        })

      # Reschedule to 2 days from now
      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated_meeting} = Reschedule.execute(meeting.uid, new_params, %{}, user.id)
      assert updated_meeting.id == meeting.id
    end

    test "handles different duration formats" do
      %{meeting: meeting} = setup_reschedule_test()

      # Using 30min duration instead of 60min
      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "3:00 PM",
        duration: "30min",
        user_timezone: "America/New_York"
      }

      assert {:ok, updated_meeting} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      assert updated_meeting.id == meeting.id
    end

    test "handles different timezone" do
      %{meeting: meeting} = setup_reschedule_test()

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "10:00 AM",
        duration: "60min",
        user_timezone: "Europe/London"
      }

      assert {:ok, updated_meeting} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      assert updated_meeting.id == meeting.id
    end
  end

  describe "Zoom video room sync" do
    test "PATCHes the Zoom meeting with new times when rescheduling" do
      %{user: user, profile: _profile} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "123456789",
          title: "Customer call"
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, url, body, headers, _opts ->
        assert url == "https://api.zoom.us/v2/meetings/123456789"
        assert {"Authorization", "Bearer access-token"} in headers

        decoded = Jason.decode!(body)
        assert decoded["topic"] == "Customer call"
        assert decoded["duration"] == 60
        assert is_binary(decoded["start_time"])

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert {:ok, _updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)
    end

    test "still reschedules successfully when Zoom update fails" do
      %{user: user, profile: _profile} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: "777"
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      stub(ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:error, :timeout}
      end)

      assert {:ok, _updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)
    end

    test "skips Zoom call when meeting has no video_room_id" do
      %{user: user, profile: _profile} = create_user_with_profile()
      integration = insert_zoom_integration(user)

      meeting =
        insert_meeting_for_user(user, %{
          video_integration_id: integration.id,
          video_room_id: nil
        })

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "2:00 PM",
        duration: "60min",
        user_timezone: "America/New_York"
      }

      # HTTPClientMock not expected — verify_on_exit! catches stray calls.
      assert {:ok, _updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)
    end
  end

  defp insert_zoom_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Zoom",
      provider: "zoom",
      base_url: nil,
      api_key_encrypted: nil,
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "meeting:write:meeting",
      provider_account_id: nil
    )
  end
end
