defmodule Tymeslot.Meetings.VideoRooms do
  @moduledoc """
  Handles video room integration for meetings.

  This module is responsible for:
  - Adding video rooms to existing meetings
  - Creating secure join URLs for organizers and participants
  - Managing video room lifecycle and expiration
  - Coordinating with video providers (MiroTalk, Teams, etc.)

  Video rooms can be added after a meeting is created, typically by an async worker.
  """

  require Logger

  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker

  # Get Video module dynamically to avoid compile-time warnings with mocks
  @spec video_module() :: module()
  defp video_module do
    Application.get_env(:tymeslot, :video_module, Video)
  end

  @doc """
  Adds a secure video room to an existing meeting.

  This function:
  1. Retrieves the meeting
  2. Verifies the organizer has video integration enabled
  3. Creates a video room via the configured provider
  4. Generates secure join URLs for organizer and participant
  5. Updates the meeting with video room details
  6. Schedules a calendar event update

  ## Parameters
    - meeting_id: The ID of the meeting to add a video room to

  ## Returns
    - {:ok, meeting} on success with video room attached
    - {:error, :meeting_not_found} if meeting doesn't exist
    - {:error, :organizer_not_found} if organizer lookup fails
    - {:error, :video_disabled} if video provider is set to "none"
    - {:error, :video_integration_missing} if no video integration configured
  - {:error, :video_integration_inactive} if integration is disabled
  - {:error, :unknown_provider} if provider is unsupported
    - {:error, reason} on other failures

  ## Examples

      iex> add_video_room_to_meeting("meeting-123")
      {:ok, %Meeting{video_room_id: "room-abc", ...}}

      iex> add_video_room_to_meeting("invalid-id")
      {:error, :meeting_not_found}
  """
  @spec add_video_room_to_meeting(String.t()) :: {:ok, MeetingSchema.t()} | {:error, term()}
  def add_video_room_to_meeting(meeting_id) do
    Repo.transaction(fn ->
      case get_meeting_for_update(meeting_id) do
        {:ok, meeting} ->
          case check_already_attached(meeting) do
            {:ok, :already_attached} ->
              meeting

            {:ok, :not_attached} ->
              with {:ok, user_id} <- get_meeting_organizer_user_id(meeting),
                   {:ok, :proceed} <- should_create_video_room(meeting, user_id) do
                create_and_attach_video_room(meeting, user_id)
              else
                {:error, reason} ->
                  Repo.rollback(reason)
              end
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # =====================================
  # Private Helper Functions
  # =====================================

  defp get_meeting_for_update(meeting_id) do
    case MeetingQueries.get_meeting_for_update(meeting_id) do
      {:ok, meeting} -> {:ok, meeting}
      {:error, :not_found} -> {:error, :meeting_not_found}
    end
  end

  defp check_already_attached(meeting) do
    if meeting.video_room_id do
      {:ok, :already_attached}
    else
      {:ok, :not_attached}
    end
  end

  defp get_meeting_organizer_user_id(meeting) do
    # First try to use organizer_user_id if available
    case meeting.organizer_user_id do
      nil ->
        # Fall back to email lookup if no user_id stored
        case UserQueries.get_user_by_email(meeting.organizer_email) do
          {:error, :not_found} ->
            {:error, :organizer_not_found}

          {:ok, user} ->
            {:ok, user.id}
        end

      user_id ->
        {:ok, user_id}
    end
  end

  defp should_create_video_room(meeting, user_id) do
    case check_video_provider_type(meeting, user_id) do
      {:ok, :none} ->
        Logger.info("Video provider is 'none', skipping video room creation",
          meeting_id: meeting.id
        )

        {:error, :video_disabled}

      {:ok, _provider_type} ->
        {:ok, :proceed}

      error ->
        error
    end
  end

  @spec create_and_attach_video_room(MeetingSchema.t(), integer() | nil) ::
          MeetingSchema.t() | no_return()
  defp create_and_attach_video_room(meeting, user_id) do
    Logger.info("Adding video room to meeting", meeting_id: meeting.id)

    # Use the specific video integration ID stored in the meeting if available
    case video_module().create_meeting_room(user_id,
           integration_id: meeting.video_integration_id,
           meeting_id: meeting.id
         ) do
      {:ok, meeting_context} ->
        with {:ok, video_room_attrs} <- build_video_room_attrs(meeting, meeting_context),
             {:ok, updated_meeting} <- update_meeting_with_video_room(meeting, video_room_attrs) do
          # After attaching the video room, update the calendar event so Google/other calendars
          # include the meeting link in description/location.
          _ = CalendarEventWorker.schedule_calendar_update(updated_meeting.id)
          updated_meeting
        else
          {:error, reason} ->
            Logger.error("Failed to process video room attributes",
              meeting_id: meeting.id,
              reason: inspect(reason)
            )

            Repo.rollback(reason)
        end

      {:error, reason} ->
        Logger.error("Failed to create video room",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        Repo.rollback(reason)
    end
  end

  @spec build_video_room_attrs(MeetingSchema.t(), map()) :: {:ok, map()}
  defp build_video_room_attrs(meeting, meeting_context) do
    with meeting_url <- get_meeting_url_from_context(meeting_context),
         room_id <- video_module().extract_room_id(meeting_context),
         {:ok, organizer_url} <- create_secure_join_url(meeting, meeting_context, "organizer"),
         {:ok, attendee_url} <- create_secure_join_url(meeting, meeting_context, "participant") do
      expiry_time = DateTime.add(meeting.end_time, 1800, :second)

      attrs = %{
        meeting_url: meeting_url,
        location: meeting_url,
        video_room_id: room_id,
        organizer_video_url: organizer_url,
        attendee_video_url: attendee_url,
        video_room_enabled: true,
        video_room_created_at: DateTime.utc_now(),
        video_room_expires_at: expiry_time
      }

      # If the video provider is Teams and we got a room_id (which is the Microsoft Event ID),
      # update the meeting UID so subsequent calendar syncs target this same event.
      attrs =
        if meeting_context.provider_type == :teams and room_id do
          Map.put(attrs, :uid, room_id)
        else
          attrs
        end

      {:ok, attrs}
    end
  end

  @spec update_meeting_with_video_room(MeetingSchema.t(), map()) ::
          {:ok, MeetingSchema.t()} | {:error, :database_update_failed}
  defp update_meeting_with_video_room(meeting, video_room_attrs) do
    case MeetingQueries.update_meeting(meeting, video_room_attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Video room added successfully",
          meeting_id: meeting.id,
          room_id: video_room_attrs.video_room_id
        )

        {:ok, updated_meeting}

      {:error, changeset} ->
        Logger.error("Failed to update meeting with video room",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, :database_update_failed}
    end
  end

  defp create_secure_join_url(meeting, meeting_context, role) do
    {participant_name, participant_email} = get_participant_info(meeting, role)

    # Try to create secure URL first
    case create_secure_url(
           meeting_context,
           participant_name,
           participant_email,
           role,
           meeting.start_time
         ) do
      {:ok, url} ->
        {:ok, url}

      {:error, reason} ->
        # Fallback to direct URL on any error
        handle_join_url_error(meeting_context, participant_name, role, reason)
    end
  end

  defp get_participant_info(meeting, "organizer") do
    {meeting.organizer_name, meeting.organizer_email}
  end

  defp get_participant_info(meeting, "participant") do
    {meeting.attendee_name, meeting.attendee_email}
  end

  defp create_secure_url(meeting_context, participant_name, participant_email, role, start_time) do
    video_module().create_join_url(
      meeting_context,
      participant_name,
      participant_email,
      role,
      start_time
    )
  rescue
    error ->
      {:error, error}
  end

  defp handle_join_url_error(meeting_context, participant_name, role, error) do
    room_id = video_module().extract_room_id(meeting_context)

    Logger.error("Failed to create secure join URL",
      room_id: room_id,
      role: role,
      error: inspect(error)
    )

    fallback_url = create_direct_join_url_fallback(room_id, participant_name)
    {:ok, fallback_url}
  end

  defp get_meeting_url_from_context(meeting_context) do
    meeting_context.room_data[:meeting_url] ||
      meeting_context.room_data["meeting_url"] ||
      meeting_context.room_data[:room_id] ||
      meeting_context.room_data["room_id"]
  end

  defp check_video_provider_type(meeting, user_id) do
    integration_result =
      case meeting.video_integration_id do
        nil -> {:error, :not_found}
        id -> VideoIntegrationQueries.get_for_user(id, user_id)
      end

    case integration_result do
      {:ok, %{is_active: false}} ->
        {:error, :video_integration_inactive}

      {:ok, integration} ->
        case integration.provider do
          "mirotalk" ->
            {:ok, :mirotalk}

          "google_meet" ->
            {:ok, :google_meet}

          "teams" ->
            {:ok, :teams}

          "custom" ->
            {:ok, :custom}

          "none" ->
            {:ok, :none}

          other ->
            Logger.warning("Unknown video provider type", provider: other)
            {:error, :unknown_provider}
        end

      {:error, :not_found} ->
        {:error, :video_integration_missing}
    end
  end

  defp get_meeting_context_from_room_id(room_id) do
    # Create a minimal context for backward compatibility
    %{
      provider_type: :mirotalk,
      room_data: %{room_id: room_id, meeting_url: room_id},
      provider_module: Tymeslot.Integrations.Video.Providers.MiroTalkProvider
    }
  end

  defp create_direct_join_url_fallback(room_id, participant_name) do
    # Fallback to direct URL creation for backward compatibility
    case video_module().create_join_url(
           get_meeting_context_from_room_id(room_id),
           participant_name,
           "",
           "participant",
           DateTime.utc_now()
         ) do
      {:ok, url} ->
        url

      {:error, _} ->
        # Ensure participant name is URL-encoded
        query = URI.encode_query(%{name: participant_name})
        "#{room_id}?#{query}"
    end
  end
end
