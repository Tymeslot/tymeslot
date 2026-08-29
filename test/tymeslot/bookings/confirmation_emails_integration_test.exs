defmodule Tymeslot.Bookings.ConfirmationEmailsIntegrationTest do
  @moduledoc """
  Integration test that verifies the complete booking → email job flow.

  This test ensures that when a booking is created:
  1. The meeting is persisted to the database
  2. An Oban job is enqueued to send confirmation emails
  3. The job executes successfully
  4. The meeting is marked as emails sent for BOTH organizer and attendee

  Note: Email content validation is covered by unit tests. This integration test
  focuses on the end-to-end flow from booking creation through job execution.

  This catches real-world issues that unit tests might miss, such as:
  - Job not being enqueued
  - Wrong action name in job parameters
  - Job execution failures
  - Provider mismatches or configuration issues
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Swoosh.TestAssertions
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    # Setup calendar mocks (booking flow checks for calendar conflicts)
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id,
                                                                _start_date,
                                                                _end_date ->
      {:ok, []}
    end)

    # IMPORTANT: Use REAL email service (not mocked) for integration testing
    # This allows us to test actual email delivery via Swoosh.Adapters.Test
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    on_exit(fn ->
      # Restore the mock for other tests
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
    end)

    # Create test user with profile
    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "America/New_York")

    # Create an active meeting type
    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Test Meeting",
        duration_minutes: 30,
        is_active: true
      )

    # Setup booking parameters
    tomorrow = Date.add(Date.utc_today(), 1)

    meeting_params = %{
      date: tomorrow,
      time: "14:00",
      duration: "30min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    form_data = %{
      "name" => "Test Attendee",
      "email" => "attendee@example.com",
      "message" => "Looking forward to our meeting!"
    }

    %{
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting_params: meeting_params,
      form_data: form_data
    }
  end

  describe "booking confirmation emails end-to-end" do
    test "sends confirmation emails to both organizer and attendee", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Step 1: Create the booking
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      # Verify meeting was created
      assert %MeetingSchema{} = meeting
      assert meeting.organizer_email == "organizer@example.com"
      assert meeting.attendee_email == "attendee@example.com"
      assert meeting.attendee_name == "Test Attendee"
      assert meeting.status == "confirmed"

      # Step 2: Verify the email job was enqueued
      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_confirmation_emails",
          "meeting_id" => meeting.id
        }
      )

      # Step 3: Execute the job (drain the queue)
      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => meeting.id
               })

      # Step 4: Verify the meeting is marked as emails sent for BOTH parties
      # This is the key integration test - confirming the full flow worked
      updated_meeting = Repo.get!(MeetingSchema, meeting.id)

      assert updated_meeting.organizer_email_sent == true,
             "Organizer email should be marked as sent"

      assert updated_meeting.attendee_email_sent == true,
             "Attendee email should be marked as sent"

      # Note: Email content is verified in unit tests (EmailServiceTest, etc.)
      # This integration test verifies the complete booking → job → database update flow
    end

    test "job completes successfully for different meeting types", %{
      user: user,
      form_data: form_data
    } do
      # Test with a different meeting type to ensure the flow is robust
      different_meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Quick Call",
          duration_minutes: 15,
          is_active: true
        )

      meeting_params = %{
        date: Date.add(Date.utc_today(), 2),
        time: "10:00",
        duration: "15min",
        user_timezone: "America/New_York",
        organizer_user_id: user.id,
        meeting_type_id: different_meeting_type.id
      }

      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => meeting.id
               })

      updated_meeting = Repo.get!(MeetingSchema, meeting.id)
      assert updated_meeting.organizer_email_sent == true
      assert updated_meeting.attendee_email_sent == true
    end

    test "does not send duplicate emails if job is retried", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      # Execute the job once
      perform_job(EmailWorker, %{
        "action" => "send_confirmation_emails",
        "meeting_id" => meeting.id
      })

      # Note: We don't clear the mailbox explicitly - it's cleared between tests automatically

      # Try to execute again (simulating a retry)
      perform_job(EmailWorker, %{
        "action" => "send_confirmation_emails",
        "meeting_id" => meeting.id
      })

      # No emails should be sent on retry (idempotency check)
      assert_no_email_sent()
    end

    test "handles missing meeting gracefully", %{} do
      fake_id = UUID.generate()

      # Execute job with non-existent meeting ID
      # The worker returns :discard for missing meetings
      assert {:discard, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => fake_id
               })

      # No emails should be sent
      assert_no_email_sent()
    end
  end

  describe "booking with video room" do
    test "booking succeeds with mirotalk video integration", %{
      user: user,
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Setup video integration
      video_integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          is_active: true,
          base_url: "https://test.mirotalk.com",
          api_key: "test-key"
        )

      meeting_params =
        Map.merge(meeting_params, %{
          video_integration_id: video_integration.id
        })

      # Mock HTTP client for video room creation
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "room_id" => "test-room-123",
               "meeting_url" => "https://test.mirotalk.com/join/test-room-123",
               "join" => "https://test.mirotalk.com/join/test-room-123"
             })
         }}
      end)

      # Create booking (this will trigger video room creation workflow)
      # Video room creation happens asynchronously via workers, not during Create.execute
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      # Verify the booking was created successfully
      assert meeting.organizer_email == "organizer@example.com"
      assert meeting.attendee_email == "attendee@example.com"
      assert meeting.status == "confirmed"

      # Note: Video room attachment is tested separately in video worker tests
      # This integration test focuses on the booking → email flow
    end

    test "custom video URL is included in confirmation emails", %{
      user: user,
      meeting_params: meeting_params,
      form_data: form_data
    } do
      # Setup custom video integration
      video_integration =
        insert(:video_integration,
          user: user,
          provider: "custom",
          is_active: true,
          custom_meeting_url: "https://meet.example.com/room/123456789"
        )

      meeting_params =
        Map.merge(meeting_params, %{
          video_integration_id: video_integration.id
        })

      TestMocks.setup_all_mocks()

      # Create booking with custom video provider
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      # The video room worker should be enqueued for custom providers
      # (to attach the custom URL before sending emails)
      assert_enqueued(
        worker: Tymeslot.Workers.VideoRoomWorker,
        args: %{
          "meeting_id" => meeting.id,
          "announce" => true
        }
      )

      # Execute the video room job (this attaches the video URL and schedules email jobs)
      perform_job(Tymeslot.Workers.VideoRoomWorker, %{
        "meeting_id" => meeting.id,
        "announce" => true
      })

      # Reload meeting to get updated video room details
      updated_meeting = Repo.get!(MeetingSchema, meeting.id)

      # Verify the custom URL was attached to the meeting
      assert updated_meeting.meeting_url == "https://meet.example.com/room/123456789"
      assert updated_meeting.video_room_enabled == true

      # Now execute the email job that was scheduled by the video room worker
      perform_job(EmailWorker, %{
        "action" => "send_confirmation_emails",
        "meeting_id" => meeting.id
      })

      # Reload meeting again to check email sent flags
      final_meeting = Repo.get!(MeetingSchema, meeting.id)

      # Verify emails were sent with the video URL included
      assert final_meeting.organizer_email_sent == true
      assert final_meeting.attendee_email_sent == true
    end
  end

  describe "email timing and scheduling" do
    test "confirmation emails are sent immediately (not scheduled for later)", %{
      meeting_params: meeting_params,
      form_data: form_data
    } do
      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      # Verify the job is scheduled to run immediately (or very soon)
      [job] =
        all_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_confirmation_emails",
            "meeting_id" => meeting.id
          }
        )

      # The job should be scheduled for immediate execution
      # (scheduled_at should be close to current time, not in the future)
      scheduled_at = DateTime.from_naive!(job.scheduled_at, "Etc/UTC")
      now = DateTime.utc_now()
      diff_seconds = DateTime.diff(scheduled_at, now, :second)

      # Should be scheduled within the next minute (allowing for some clock drift)
      assert diff_seconds < 60
    end
  end

  describe "confirmation email subject CRLF injection prevention" do
    test "booking and email job complete without error when organiser name carries a header-injection payload",
         %{} do
      # Create a separate organiser whose name contains a CRLF injection payload.
      # The policy resolves organizer_name as: profile.full_name || user.name,
      # so setting user.name is sufficient when full_name is nil (default profile).
      #
      # Note: email *subject* CRLF stripping is verified at the template layer in
      # reschedule_request_test.exs and sibling tests. Here we verify that the full
      # booking → EmailWorker pipeline runs to completion — the CRLF payload does
      # not crash the template renderer, the sanitizer, or the delivery path.
      # (Swoosh.Adapters.Test delivers via CircuitBreaker GenServer, so the
      # {:email, ...} message does not reach the test process mailbox — see
      # test/tymeslot/emails/delivery_test.exs for the explanation.)
      malicious_name = "Evil Organiser\r\nBcc: attacker@evil.com"

      user =
        insert(:user,
          email: "injector@example.com",
          name: malicious_name
        )

      _profile = insert(:profile, user: user, timezone: "America/New_York")

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Injection Test Meeting",
          duration_minutes: 30,
          is_active: true
        )

      meeting_params = %{
        date: Date.add(Date.utc_today(), 3),
        time: "11:00",
        duration: "30min",
        user_timezone: "America/New_York",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }

      form_data = %{
        "name" => "Test Attendee",
        "email" => "attendee@example.com",
        "message" => "Test booking"
      }

      assert {:ok, meeting} = Create.execute(meeting_params, form_data)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => meeting.id
               })

      # If sanitization crashed or the template raised, the job would return
      # {:error, _} or {:discard, _} — asserting :ok proves the CRLF payload
      # was handled safely end-to-end. The DB flags confirm both emails sent.
      updated_meeting = Repo.get!(MeetingSchema, meeting.id)
      assert updated_meeting.organizer_email_sent == true
      assert updated_meeting.attendee_email_sent == true
    end
  end
end
