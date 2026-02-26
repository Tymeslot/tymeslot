defmodule Tymeslot.TestMocks do
  @moduledoc """
  Centralized mock setup for tests to reduce duplication and improve maintainability.

  This module provides pre-configured mock setups for all external services and
  dependencies, making it easy to write tests without worrying about mock configuration.

  ## Why Use This?

  Instead of manually setting up mocks in every test:

      setup do
        stub(Tymeslot.MiroTalkAPIMock, :create_meeting_room, fn _ ->
          {:ok, "https://test.mirotalk.com/join/room"}
        end)
        stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _, _, _ ->
          {:ok, []}
        end)
        # ... many more stubs
      end

  You can write:

      setup do
        setup_all_mocks()  # Sets up all common mocks with sensible defaults
      end

  ## Common Scenarios

  ### Complete Booking Flow Tests

  For tests that exercise the full booking flow (calendar check, video room creation, email sending):

      setup :verify_on_exit!
      setup do
        setup_all_mocks()
      end

      test "creates booking with video link" do
        user = create_user_fixture()
        # All external services are mocked and will succeed
      end

  ### Video Meeting Tests

  For tests focused on video provider integration:

      setup do
        setup_mirotalk_mocks(
          room_url: "https://custom.mirotalk.com/join/custom-room"
        )
      end

      test "generates custom video link" do
        assert create_video_meeting() == {:ok, "https://custom.mirotalk.com/join/custom-room"}
      end

  ### Calendar Sync Tests

  For tests that need existing calendar events:

      setup do
        setup_calendar_mocks(
          events: [
            mock_calendar_event(
              summary: "Existing Meeting",
              start_time: ~U[2024-01-15 10:00:00Z],
              end_time: ~U[2024-01-15 10:30:00Z]
            ),
            mock_calendar_event(
              summary: "Another Meeting",
              start_time: ~U[2024-01-15 14:00:00Z],
              end_time: ~U[2024-01-15 15:00:00Z]
            )
          ]
        )
      end

      test "detects conflicts with existing meetings" do
        conflicts = find_conflicts(user, ~U[2024-01-15 10:15:00Z])
        assert length(conflicts) == 1
      end

  ### Error Scenario Tests

  For testing error handling and resilience:

      setup do
        setup_error_mocks(:mirotalk_failure)
      end

      test "handles video provider failure gracefully" do
        assert {:error, _} = create_meeting_with_video()
        assert_email_sent()  # Booking still created, fallback to no video
      end

  ### Email Delivery Tests

  For testing notification logic without sending real emails:

      setup do
        setup_email_mocks()  # All emails succeed by default
      end

      test "sends confirmation to both parties" do
        create_booking()
        assert_received {:email_sent, %{to: organizer_email}}
        assert_received {:email_sent, %{to: attendee_email}}
      end

  ### Testing Email Failures

      setup do
        setup_email_mocks(send_result: {:error, "SMTP timeout"})
      end

      test "logs email failure but completes booking" do
        assert {:ok, booking} = create_booking()
        assert booking.status == "confirmed"
        # Email failure is logged but doesn't fail the booking
      end

  ## Available Mock Types

  ### 1. Video Providers (MiroTalk)

      setup_mirotalk_mocks()  # Default: successful room creation
      setup_mirotalk_mocks(room_url: "custom_url")
      setup_mirotalk_mocks(create_result: {:error, "API down"})

  ### 2. Calendar Services

      setup_calendar_mocks()  # Default: empty calendar
      setup_calendar_mocks(events: [event1, event2])
      setup_calendar_mocks(result: {:error, "Auth failed"})

  ### 3. Email Service

      setup_email_mocks()  # Default: all emails succeed
      setup_email_mocks(send_result: {:error, "SMTP error"})

  ### 4. Subscription Manager (SaaS)

      setup_subscription_mocks()  # Default: show branding
      setup_subscription_mocks(show_branding: false)

  ### 5. All Services

      setup_all_mocks()  # Sets up all services with success defaults

  ### 6. Error Scenarios

      setup_error_mocks(:mirotalk_failure)
      setup_error_mocks(:calendar_failure)
      setup_error_mocks(:email_failure)

  ## Mock Expectations vs Stubs

  This module uses Mox `stub/3` by default, which allows the mock to be called
  zero or more times. For tests that need to verify a specific number of calls,
  use `expect/4` directly:

      setup do
        setup_all_mocks()  # Sets up default stubs

        # Override with specific expectation
        expect(Tymeslot.MiroTalkAPIMock, :create_meeting_room, 1, fn config ->
          assert config.api_key == "expected_key"
          {:ok, "https://room.url"}
        end)
      end

  ## Testing Multiple Scenarios

  You can override mocks per-test even after setup:

      setup do
        setup_all_mocks()
      end

      test "handles success" do
        # Uses default successful mocks from setup
        assert {:ok, _} = create_booking()
      end

      test "handles video failure" do
        # Override just the video mock for this test
        stub(Tymeslot.MiroTalkAPIMock, :create_meeting_room, fn _ ->
          {:error, "Service unavailable"}
        end)

        assert {:error, _} = create_booking()
      end

  ## Integration with Test Helpers

  This module is automatically imported when using `Tymeslot.TestHelpers`:

      use Tymeslot.TestHelpers

      # Now you can use setup_all_mocks() and other functions
  """

  import Mox

  @doc """
  Sets up MiroTalk API mocks with default successful responses.

  ## Options

  - `:room_url` - The video room URL to return (default: "https://test.mirotalk.com/join/test-room-123")
  - `:room_id` - The room ID (default: "test-room-123")
  - `:create_result` - Override the create_meeting_room result (default: `{:ok, room_url}`)

  ## Examples

      # Basic successful video room creation
      setup_mirotalk_mocks()

      # Custom room URL
      setup_mirotalk_mocks(room_url: "https://prod.mirotalk.com/join/prod-room")

      # Simulate video provider failure
      setup_mirotalk_mocks(create_result: {:error, "MiroTalk API unavailable"})

  ## Mocked Functions

  - `create_meeting_room/1` - Returns the configured room URL or error
  - `extract_room_id/1` - Extracts room ID from URL
  - `create_direct_join_url/2` - Creates participant join URL with name
  - `create_secure_direct_join_url/4` - Creates role-based join URL with tokens
  """
  @spec setup_mirotalk_mocks(keyword()) :: term()
  def setup_mirotalk_mocks(opts \\ []) do
    room_url = Keyword.get(opts, :room_url, "https://test.mirotalk.com/join/test-room-123")
    _default_room_id = Keyword.get(opts, :room_id, "test-room-123")
    create_result = Keyword.get(opts, :create_result, {:ok, room_url})

    Tymeslot.MiroTalkAPIMock
    |> stub(:create_meeting_room, fn _config -> create_result end)
    |> stub(:extract_room_id, fn url ->
      case String.contains?(url, "/join/") do
        true -> url |> String.split("/join/") |> List.last()
        false -> nil
      end
    end)
    |> stub(:create_direct_join_url, fn room_id, participant_name ->
      "#{room_url}?name=#{URI.encode(participant_name)}&room_id=#{room_id}"
    end)
    |> stub(:create_secure_direct_join_url, fn _room_id, name, role, _datetime ->
      case role do
        "organizer" -> "#{room_url}?role=organizer&token=org123"
        "attendee" -> "#{room_url}?role=attendee&token=att456"
        _other -> "#{room_url}?name=#{URI.encode(name)}&role=#{role}"
      end
    end)
  end

  @doc """
  Sets up Calendar mocks with configurable responses.

  ## Options

  - `:events` - List of calendar events to return (default: `[]`)
  - `:result` - Override the result tuple (default: `{:ok, events}`)
  - `:google_oauth_url` - Google OAuth authorization URL
  - `:outlook_oauth_url` - Outlook OAuth authorization URL

  ## Examples

      # Empty calendar (no conflicts)
      setup_calendar_mocks()

      # Calendar with existing meetings
      setup_calendar_mocks(
        events: [
          mock_calendar_event(summary: "Team Meeting", start_time: ~U[2024-01-15 10:00:00Z]),
          mock_calendar_event(summary: "Lunch Break", start_time: ~U[2024-01-15 12:00:00Z])
        ]
      )

      # Simulate calendar connection failure
      setup_calendar_mocks(result: {:error, "Calendar authorization expired"})

      # Custom OAuth URLs for integration testing
      setup_calendar_mocks(
        google_oauth_url: "https://test.google.com/oauth?state=test"
      )

  ## Mocked Functions

  - `list_events_in_range/3` - Returns configured events or error
  - `get_events_for_range_fresh/3` - Same as list_events_in_range
  - `get_booking_integration_info/1` - Returns `{:error, :no_integration}` by default
  - Google/Outlook OAuth helpers for authorization URLs
  """
  @spec setup_calendar_mocks(keyword()) :: term()
  def setup_calendar_mocks(opts \\ []) do
    events = Keyword.get(opts, :events, [])
    result = Keyword.get(opts, :result, {:ok, events})

    Tymeslot.CalendarMock
    |> stub(:list_events_in_range, fn _user_id, _start_time, _end_time -> result end)
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> result end)
    |> stub(:get_booking_integration_info, fn _user_id ->
      {:error, :no_integration}
    end)

    # Setup OAuth helper mocks
    google_url =
      Keyword.get(opts, :google_oauth_url, "https://accounts.google.com/o/oauth2/v2/auth?test=1")

    outlook_url =
      Keyword.get(
        opts,
        :outlook_oauth_url,
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?test=1"
      )

    stub(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri ->
      google_url
    end)

    stub(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri ->
      outlook_url
    end)
  end

  @doc """
  Sets up Email Service mocks for all notification types.

  ## Options

  - `:send_result` - Result to return for all email sends (default: `:ok`)

  ## Examples

      # All emails succeed
      setup_email_mocks()

      # Simulate email delivery failures
      setup_email_mocks(send_result: {:error, "SMTP connection timeout"})

      # Test retry logic
      setup_email_mocks(send_result: {:error, "Temporary failure"})

  ## Mocked Functions

  All email notification types are stubbed:
  - Appointment confirmations (organizer & attendee)
  - Appointment reminders (organizer & attendee)
  - Cancellation notifications
  - Calendar sync error notifications
  - Email verification
  - Password reset
  - Email change notifications

  ## Testing Email Delivery

  To verify emails were sent, use assertions from `Tymeslot.TestAssertions`:

      setup_email_mocks()
      create_booking()
      assert_email_sent(to: "attendee@example.com", subject: "Appointment Confirmed")
  """
  @spec setup_email_mocks(keyword()) :: term()
  def setup_email_mocks(opts \\ []) do
    send_result = Keyword.get(opts, :send_result, :ok)

    Tymeslot.EmailServiceMock
    |> stub(:send_appointment_confirmation_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_confirmation_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_appointment_confirmations, fn _details -> {send_result, send_result} end)
    |> stub(:send_appointment_reminder_to_organizer, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminder_to_attendee, fn _email, _details -> send_result end)
    |> stub(:send_appointment_reminders, fn _details -> {send_result, send_result} end)
    |> stub(:send_appointment_reminders, fn _details, _time -> {send_result, send_result} end)
    |> stub(:send_appointment_cancellation, fn _email, _details -> send_result end)
    |> stub(:send_cancellation_emails, fn _details -> {send_result, send_result} end)
    |> stub(:send_calendar_sync_error, fn _meeting, _error -> send_result end)
    |> stub(:send_email_verification, fn _user, _url -> send_result end)
    |> stub(:send_password_reset, fn _user, _url -> send_result end)
    |> stub(:send_email_change_verification, fn _user, _email, _url -> send_result end)
    |> stub(:send_email_change_notification, fn _user, _email -> send_result end)
    |> stub(:send_email_change_confirmations, fn _user, _old, _new ->
      {send_result, send_result}
    end)
    |> stub(:send_reschedule_request, fn _meeting -> send_result end)
  end

  @doc """
  Sets up Subscription Manager mocks.
  """
  @spec setup_subscription_mocks(keyword()) :: term()
  def setup_subscription_mocks(opts \\ []) do
    show_branding = Keyword.get(opts, :show_branding, true)

    stub(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, fn _user_id ->
      show_branding
    end)
  end

  @doc """
  Sets up all standard mocks for a typical successful flow.

  This is the most commonly used mock setup function. It configures all external
  services to return successful responses, making it easy to write happy-path tests.

  ## What It Sets Up

  - **MiroTalk (Video)**: Room creation succeeds, returns test room URL
  - **Calendar**: Empty calendar (no conflicts), OAuth URLs configured
  - **Email**: All notifications deliver successfully
  - **Subscription**: Branding displayed by default

  ## Example

      setup :verify_on_exit!
      setup do
        setup_all_mocks()
      end

      test "complete booking flow" do
        user = create_user_fixture()
        profile = insert(:profile, user: user)

        # All external services are mocked and will succeed
        assert {:ok, meeting} = create_meeting(profile, attendee_email: "test@example.com")
        assert meeting.video_link =~ "mirotalk.com"
      end

  ## Overriding Individual Services

  You can call setup_all_mocks() and then override specific services:

      setup do
        setup_all_mocks()

        # Override just the calendar to have conflicts
        setup_calendar_mocks(
          events: [mock_calendar_event(start_time: conflict_time)]
        )
      end
  """
  @spec setup_all_mocks() :: term()
  def setup_all_mocks do
    setup_mirotalk_mocks()
    setup_calendar_mocks()
    setup_email_mocks()
    setup_subscription_mocks()
  end

  # Internal Stripe behaviours for testing the Stripe wrapper.
  # These are defined here to avoid duplication in test helpers.
  defmodule StripeCustomerBehaviour do
    @moduledoc "Behaviour for Stripe Customer operations"
    @callback create(map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeSessionBehaviour do
    @moduledoc "Behaviour for Stripe Session operations"
    @callback create(map(), list()) :: {:ok, map()} | {:error, any()}
    @callback retrieve(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
    @callback expire(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeSubscriptionBehaviour do
    @moduledoc "Behaviour for Stripe Subscription operations"
    @callback create(map(), list()) :: {:ok, map()} | {:error, any()}
    @callback retrieve(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
    @callback update(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
    @callback cancel(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeChargeBehaviour do
    @moduledoc "Behaviour for Stripe Charge operations"
    @callback retrieve(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeWebhookBehaviour do
    @moduledoc "Behaviour for Stripe Webhook operations"
    @callback construct_event(binary(), String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  end

  @doc """
  Sets up mocks for error scenarios to test failure handling and resilience.

  This function configures one service to fail while keeping others operational,
  allowing you to test how your code handles specific failure modes.

  ## Available Error Types

  - `:mirotalk_failure` - Video room creation fails, calendar and email work
  - `:calendar_failure` - Calendar sync fails, video and email work
  - `:email_failure` - Email delivery fails, video and calendar work

  ## Examples

      # Test video provider failure
      setup do
        setup_error_mocks(:mirotalk_failure)
      end

      test "creates meeting without video when provider fails" do
        assert {:ok, meeting} = create_meeting()
        assert is_nil(meeting.video_link)
        # Meeting still created, email still sent
      end

      # Test calendar connection issues
      setup do
        setup_error_mocks(:calendar_failure)
      end

      test "allows booking when calendar unavailable" do
        # Should proceed with booking even if can't check calendar
        assert {:ok, meeting} = create_meeting()
        # Warning should be logged but booking succeeds
      end

      # Test email delivery failures
      setup do
        setup_error_mocks(:email_failure)
      end

      test "completes booking even when email fails" do
        assert {:ok, meeting} = create_meeting()
        assert meeting.status == "confirmed"
        # Email failure logged but doesn't block booking
      end

  ## Testing Multiple Failures

  For testing cascading failures, set up mocks individually:

      setup do
        setup_mirotalk_mocks(create_result: {:error, "API down"})
        setup_calendar_mocks(result: {:error, "Auth expired"})
        setup_email_mocks(send_result: {:error, "SMTP timeout"})
      end

      test "handles complete service outage gracefully" do
        # System should degrade gracefully, not crash
        assert {:ok, meeting} = create_meeting()
      end
  """
  @spec setup_error_mocks(atom()) :: term()
  def setup_error_mocks(error_type) do
    case error_type do
      :mirotalk_failure ->
        setup_mirotalk_mocks(create_result: {:error, "MiroTalk API error"})
        setup_calendar_mocks()
        setup_email_mocks()

      :calendar_failure ->
        setup_mirotalk_mocks()
        setup_calendar_mocks(result: {:error, "Calendar connection failed"})
        setup_email_mocks()

      :email_failure ->
        setup_mirotalk_mocks()
        setup_calendar_mocks()
        setup_email_mocks(send_result: {:error, "Email delivery failed"})
    end
  end

  @doc """
  Creates a mock calendar event for testing calendar integration and conflict detection.

  ## Options

  - `:summary` - Event title/subject (default: "Test Meeting")
  - `:start_time` - Event start DateTime (default: `DateTime.utc_now()`)
  - `:end_time` - Event end DateTime (default: 30 minutes after start)
  - `:uid` - Unique event identifier (default: auto-generated)

  ## Examples

      # Basic event with defaults
      event = mock_calendar_event()

      # Specific time slot
      event = mock_calendar_event(
        summary: "Team Standup",
        start_time: ~U[2024-01-15 09:00:00Z],
        end_time: ~U[2024-01-15 09:30:00Z]
      )

      # Create multiple events for conflict testing
      events = [
        mock_calendar_event(summary: "Morning Meeting", start_time: ~U[2024-01-15 09:00:00Z]),
        mock_calendar_event(summary: "Lunch", start_time: ~U[2024-01-15 12:00:00Z]),
        mock_calendar_event(summary: "Afternoon Meeting", start_time: ~U[2024-01-15 14:00:00Z])
      ]

      setup_calendar_mocks(events: events)

      # All-day event (same start and end date)
      all_day = mock_calendar_event(
        summary: "Conference",
        start_time: ~U[2024-01-15 00:00:00Z],
        end_time: ~U[2024-01-15 23:59:59Z]
      )

  ## Use in Tests

      setup do
        setup_calendar_mocks(
          events: [
            mock_calendar_event(start_time: conflict_time, end_time: conflict_time_end)
          ]
        )
      end

      test "detects scheduling conflicts" do
        # Attempt to book at a time that overlaps with existing event
        assert {:error, :conflict} = book_meeting(time: conflict_time)
      end
  """
  @spec mock_calendar_event(keyword()) :: map()
  def mock_calendar_event(opts \\ []) do
    %{
      summary: Keyword.get(opts, :summary, "Test Meeting"),
      start_time: Keyword.get(opts, :start_time, DateTime.utc_now()),
      end_time: Keyword.get(opts, :end_time, DateTime.add(DateTime.utc_now(), 30, :minute)),
      uid: Keyword.get(opts, :uid, "test-uid-#{System.unique_integer([:positive])}")
    }
  end
end
