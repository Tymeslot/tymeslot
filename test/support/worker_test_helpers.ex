defmodule Tymeslot.WorkerTestHelpers do
  @moduledoc """
  Shared helper functions for worker tests to reduce duplication and improve maintainability.
  """

  import Mox
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema

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
