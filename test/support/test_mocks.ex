defmodule Tymeslot.TestMocks do
  @moduledoc """
  Centralized mock setup for tests to reduce duplication and improve maintainability.

  This module is a thin facade over per-service mock modules under
  `Tymeslot.Mocks.*`. It provides pre-configured mock setups for all external
  services and dependencies, making it easy to write tests without worrying
  about mock configuration.

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
        setup_all_mocks()

        expect(Tymeslot.MiroTalkAPIMock, :create_meeting_room, 1, fn config ->
          assert config.api_key == "expected_key"
          {:ok, "https://room.url"}
        end)
      end

  ## Integration with Test Helpers

  This module is automatically imported when using `Tymeslot.TestHelpers`:

      use Tymeslot.TestHelpers
  """

  alias Tymeslot.Mocks

  @doc """
  Sets up MiroTalk API mocks with default successful responses.

  ## Options

  - `:room_url` - The video room URL to return
  - `:create_result` - Override the create_meeting_room result
  """
  @spec setup_mirotalk_mocks(keyword()) :: term()
  defdelegate setup_mirotalk_mocks(opts \\ []), to: Mocks.MiroTalk, as: :setup

  @doc """
  Sets up Calendar mocks with configurable responses.

  ## Options

  - `:events` - List of calendar events to return (default: `[]`)
  - `:result` - Override the result tuple (default: `{:ok, events}`)
  - `:google_oauth_url` / `:outlook_oauth_url` - Authorization URLs
  """
  @spec setup_calendar_mocks(keyword()) :: term()
  defdelegate setup_calendar_mocks(opts \\ []), to: Mocks.Calendar, as: :setup

  @doc """
  Stubs the calendar read paths to return no events. Lighter than
  `setup_calendar_mocks/1` when a test only needs "this user has no conflicting
  calendar events".
  """
  @spec stub_no_calendar_events() :: term()
  defdelegate stub_no_calendar_events(), to: Mocks.Calendar, as: :stub_no_events

  @doc """
  Sets up Email Service mocks for all notification types.

  ## Options

  - `:send_result` - Result returned by every send_* function (default: `:ok`)
  """
  @spec setup_email_mocks(keyword()) :: term()
  defdelegate setup_email_mocks(opts \\ []), to: Mocks.Email, as: :setup

  @doc """
  Sets up Subscription Manager mocks.
  """
  @spec setup_subscription_mocks(keyword()) :: term()
  defdelegate setup_subscription_mocks(opts \\ []), to: Mocks.Subscription, as: :setup

  @doc """
  Sets up HTTP client mocks with a transport timeout fallback.
  """
  @spec setup_http_client_mocks() :: term()
  defdelegate setup_http_client_mocks(), to: Mocks.HTTPClient, as: :setup

  @doc """
  Creates a mock calendar event for testing calendar integration and conflict detection.

  ## Options

  - `:summary`, `:start_time`, `:end_time`, `:uid`
  """
  @spec mock_calendar_event(keyword()) :: map()
  defdelegate mock_calendar_event(opts \\ []), to: Mocks.Calendar, as: :event

  @doc """
  Sets up all standard mocks for a typical successful flow.

  Configures MiroTalk, Calendar, Email, Subscription, and HTTP Client mocks
  with success defaults so happy-path tests need no further setup.
  """
  @spec setup_all_mocks() :: term()
  def setup_all_mocks do
    setup_mirotalk_mocks()
    setup_calendar_mocks()
    setup_email_mocks()
    setup_subscription_mocks()
    setup_http_client_mocks()
  end

  @doc """
  Sets up mocks for error scenarios to test failure handling and resilience.

  ## Available Error Types

  - `:mirotalk_failure` - Video room creation fails, calendar and email work
  - `:calendar_failure` - Calendar sync fails, video and email work
  - `:email_failure` - Email delivery fails, video and calendar work
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
end
