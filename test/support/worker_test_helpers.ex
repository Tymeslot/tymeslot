defmodule Tymeslot.WorkerTestHelpers do
  @moduledoc """
  Shared helper functions for worker tests to reduce duplication and improve maintainability.
  """

  import Mox
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @doc """
  Inserts an `unhealthy` integration health state row for the given user and
  integration. Used by tests for `IntegrationAutoPauseWorker` and the recovery
  flow to seed deterministic unhealthy state.

  ## Options
    * `:became_unhealthy_at` (default: `DateTime.utc_now/0`)
    * `:consecutive_hard_failures` (default: `5`)
  """
  @spec insert_unhealthy_health_row(UserSchema.t(), :calendar | :video, term(), keyword()) ::
          IntegrationHealthStateSchema.t()
  def insert_unhealthy_health_row(user, type, integration_id, opts \\ []) do
    became_unhealthy_at = Keyword.get(opts, :became_unhealthy_at, DateTime.utc_now())
    consecutive_hard_failures = Keyword.get(opts, :consecutive_hard_failures, 5)

    %IntegrationHealthStateSchema{}
    |> IntegrationHealthStateSchema.changeset(%{
      integration_type: Atom.to_string(type),
      integration_id: integration_id,
      user_id: user.id,
      status: "unhealthy",
      failures: max(consecutive_hard_failures, 5),
      consecutive_hard_failures: consecutive_hard_failures,
      successes: 0,
      backoff_ms: :timer.hours(1),
      last_check_at: DateTime.utc_now(),
      last_error_class: "hard",
      became_unhealthy_at: became_unhealthy_at,
      notification_sent_at: DateTime.add(became_unhealthy_at, 2 * 24 * 3600, :second)
    })
    |> Repo.insert!()
  end

  @doc """
  Sets up a complete calendar scenario with user, integration, and meeting.

  ## Options
    * `:uid` - Meeting UID (default: a new UUID)
    * `:with_calendar_path` - Include calendar_path in meeting (default: true)
  """
  @spec setup_calendar_scenario(keyword()) :: %{
          user: UserSchema.t(),
          integration: CalendarIntegrationSchema.t(),
          meeting: MeetingSchema.t()
        }
  def setup_calendar_scenario(opts \\ []) do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user)

    meeting_attrs = %{
      organizer_user_id: user.id,
      calendar_integration_id: integration.id,
      uid: Keyword.get(opts, :uid, UUID.generate())
    }

    meeting_attrs =
      if Keyword.get(opts, :with_calendar_path, true) do
        Map.put(meeting_attrs, :calendar_path, "primary")
      else
        meeting_attrs
      end

    meeting = insert(:meeting, meeting_attrs)

    %{user: user, integration: integration, meeting: meeting}
  end

  @doc """
  Sets up a complete calendar scenario with user, CalDAV integration with calendar_paths
  populated, and meeting.

  Use this variant when the test exercises code that writes to provider_calendar_events,
  which requires a non-null provider_calendar_id — derived from `integration.calendar_paths`.
  """
  @spec setup_calendar_scenario_with_paths(keyword()) :: %{
          user: UserSchema.t(),
          integration: CalendarIntegrationSchema.t(),
          meeting: MeetingSchema.t()
        }
  def setup_calendar_scenario_with_paths(opts \\ []) do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, calendar_paths: ["primary"])

    meeting_attrs = %{
      organizer_user_id: user.id,
      calendar_integration_id: integration.id,
      calendar_path: "primary",
      uid: Keyword.get(opts, :uid, UUID.generate())
    }

    meeting = insert(:meeting, meeting_attrs)

    %{user: user, integration: integration, meeting: meeting}
  end

  @doc """
  Sets up a video integration scenario with user and meeting.
  """
  @spec setup_video_scenario(keyword()) :: %{
          user: UserSchema.t(),
          integration: VideoIntegrationSchema.t(),
          meeting: MeetingSchema.t()
        }
  def setup_video_scenario(opts \\ []) do
    user = insert(:user)
    _profile = insert(:profile, user: user)

    integration =
      insert(:video_integration,
        user: user,
        provider: Keyword.get(opts, :provider, "mirotalk")
      )

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        video_integration_id: integration.id
      )

    %{user: user, integration: integration, meeting: meeting}
  end

  @doc """
  Mocks a successful calendar event creation including the post-creation integration info fetch.
  """
  @spec expect_calendar_create_success(integer(), String.t()) :: :ok
  def expect_calendar_create_success(integration_id, returned_uid \\ "remote-uid-123") do
    # Mock the event creation
    expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
      {:ok, returned_uid}
    end)

    # Mock the post-creation integration info fetch (called by persist_calendar_mapping)
    expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:ok, %{integration_id: integration_id, calendar_path: "primary"}}
    end)
  end

  @doc """
  Mocks a successful calendar event update.
  """
  @spec expect_calendar_update_success() :: :ok
  def expect_calendar_update_success do
    expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _integration_id ->
      :ok
    end)
  end

  @doc """
  Mocks a successful calendar event deletion.
  """
  @spec expect_calendar_delete_success() :: :ok
  def expect_calendar_delete_success do
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _integration_id ->
      :ok
    end)
  end

  @doc """
  Mocks a successful HTTP POST request.
  """
  @spec expect_http_success(integer(), String.t()) :: :ok
  def expect_http_success(status_code \\ 200, body \\ "OK") do
    expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: status_code, body: body}}
    end)
  end

  @doc """
  Mocks a successful MiroTalk video room creation with all required API calls.

  MiroTalk requires multiple API calls:
  1. POST /api/v1/meeting - Creates the room (returns meeting URL)
  2. POST /api/v1/join - Generates organizer join token
  3. POST /api/v1/join - Generates participant join token
  """
  @spec expect_zoom_success(String.t()) :: :ok
  def expect_zoom_success(join_url \\ "https://zoom.us/j/12345678901") do
    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok,
       %Req.Response{
         status: 201,
         body:
           Jason.encode!(%{
             "id" => 12_345_678_901,
             "join_url" => join_url,
             "password" => "test123",
             "start_url" => "#{join_url}?zak=host-token",
             "host_email" => "host@example.com"
           })
       }}
    end)
  end

  @spec expect_mirotalk_success(String.t()) :: :ok
  def expect_mirotalk_success(room_url \\ "https://test.mirotalk.com/join/test-room-123") do
    # First two calls: room creation
    Tymeslot.HTTPClientMock
    |> expect(:post, 2, fn url, _body, _headers, _opts ->
      body =
        if String.contains?(url, "/api/v1/meeting") do
          Jason.encode!(%{"meeting" => room_url})
        else
          "{}"
        end

      {:ok, %Req.Response{status: 200, body: body}}
    end)
    # Next two calls: join token generation for organizer and participant
    |> expect(:post, 2, fn _url, _body, _headers, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"join" => "#{room_url}?token=abc"})
       }}
    end)
  end
end
