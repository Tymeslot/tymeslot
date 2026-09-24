defmodule Tymeslot.Meetings.VideoRooms do
  @moduledoc """
  Handles video room integration for meetings.

  This module is responsible for:
  - Adding video rooms to existing meetings
  - Creating secure join URLs for organizers and participants, and the
    identity-free one a booking's guests share (`guest_join_url/1`)
  - Managing video room lifecycle and expiration
  - Coordinating with video providers (MiroTalk, Meet, Teams, etc.)

  Video rooms can be added after a meeting is created, typically by an async worker.

  ## Transaction boundaries

  The external HTTP call to the video provider is made **outside** any database
  transaction. Only the final "attach the generated room to the meeting" write is
  wrapped in a short transaction that re-locks the meeting row and re-checks the
  idempotency condition, so that a concurrent worker that already attached a room
  is detected and the second caller receives `{:ok, meeting}` without a duplicate
  provider call affecting the database. This prevents a slow video provider from
  holding a database connection for the duration of the remote request.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Meetings.{MeetingQueries, MeetingSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.UrlValidation
  alias Tymeslot.Workers.VideoSyncWorker

  # The meeting has no reachable room to rebuild links for: the organiser or
  # the integration is gone, or the integration was switched off.
  @quiet_refresh_skips [
    :organizer_not_found,
    :video_integration_missing,
    :video_integration_inactive
  ]

  # Get Video module dynamically to avoid compile-time warnings with mocks
  @spec video_module() :: module()
  defp video_module do
    Application.get_env(:tymeslot, :video_module, Video)
  end

  @doc """
  Adds a secure video room to an existing meeting.

  This function:
  1. Retrieves the meeting (no transaction) and checks idempotency
  2. Verifies the organizer has video integration enabled (no transaction)
  3. Creates a video room via the configured provider (no transaction — external HTTP)
  4. Generates secure join URLs for organizer and participant (no transaction)
  5. Inside a short transaction: re-locks the meeting, re-checks idempotency,
     and persists the video room attributes
  6. Schedules a calendar event update

  ## Parameters
    - meeting_id: The ID of the meeting to add a video room to

  ## Returns
    - {:ok, meeting} on success with video room attached
    - {:ok, meeting} if the meeting already has a room attached (idempotent)
    - {:error, :meeting_not_found} if meeting doesn't exist
    - {:error, :organizer_not_found} if organizer lookup fails
    - {:error, :video_disabled} if video provider is set to "none"
    - {:error, :video_integration_missing} if no video integration configured
    - {:error, :video_integration_inactive} if integration is disabled
    - {:error, :unknown_provider} if provider is unsupported
    - {:error, :incomplete_video_room} if the provider returned a room carrying
      neither a room id nor a meeting URL
    - {:error, :join_url_unavailable} if the provider could not mint a join URL
      and the room carries no usable URL to fall back on
    - {:error, :database_update_failed} if the final write fails
    - {:error, reason} on other failures

  ## Examples

      iex> add_video_room_to_meeting("meeting-123")
      {:ok, %Meeting{video_room_id: "room-abc", ...}}

      iex> add_video_room_to_meeting("invalid-id")
      {:error, :meeting_not_found}
  """
  @spec add_video_room_to_meeting(String.t()) :: {:ok, MeetingSchema.t()} | {:error, term()}
  def add_video_room_to_meeting(meeting_id) do
    with {:ok, meeting} <- fetch_meeting(meeting_id),
         :not_attached <- attached_status(meeting),
         {:ok, user_id} <- get_meeting_organizer_user_id(meeting),
         {:ok, :proceed} <- should_create_video_room(meeting, user_id),
         {:ok, meeting_context} <- create_provider_meeting_room(meeting, user_id),
         {:ok, video_room_attrs} <- build_video_room_attrs(meeting, meeting_context) do
      persist_video_room(meeting, video_room_attrs)
    else
      {:already_attached, meeting} -> {:ok, meeting}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Builds a meeting's join URLs again for a new start time, when its provider's
  join URLs stop working some time after the time they were built for.

  Meant for a reschedule: the result is merged into the same write that moves
  the meeting, so every reader of `organizer_video_url` and
  `attendee_video_url` downstream (the reschedule emails, calendar sync,
  webhook deliveries, reminders) sees links valid for the new time. The room
  itself is left alone: `video_room_id` and `meeting_url` are never part of
  the result, and the provider is never asked for a new room.

  Returns `%{organizer_video_url: url, attendee_video_url: url}` when the links
  were rebuilt, and `%{}` when there is nothing to rebuild or rebuilding
  failed, in which case the stored links are kept. It never raises: a failure
  here must not stand in the way of the reschedule itself.

  Only providers declaring time-bound join URLs are rebuilt (see
  `Tymeslot.Integrations.Video.Providers.ProviderBehaviour`'s
  `time_bound_join_urls?/1`), which also keeps providers whose join URLs need
  a network call out of this inline path. A meeting without a room, or whose
  integration is gone or inactive, is skipped without logging, as room
  creation skips it.

  Unlike `Tymeslot.Workers.VideoSyncWorker`, this deliberately does not fall
  back to another integration for the same provider through
  `Tymeslot.Integrations.Video.IntegrationResolver`. A reconnected Jitsi
  integration may point at a different server or hold a different secret, so
  tokens signed with it for the old room would be wrong; skipping keeps the
  stored links instead.
  """
  @spec refreshed_join_url_attrs(MeetingSchema.t(), DateTime.t()) ::
          %{optional(:organizer_video_url | :attendee_video_url) => String.t()}
  def refreshed_join_url_attrs(%MeetingSchema{video_room_id: nil}, _start_time), do: %{}

  def refreshed_join_url_attrs(%MeetingSchema{} = meeting, %DateTime{} = start_time) do
    rescheduled = %{meeting | start_time: start_time}

    with {:ok, user_id} <- get_meeting_organizer_user_id(meeting),
         {:ok, provider_type} when provider_type != :none <-
           check_video_provider_type(meeting, user_id),
         {:ok, meeting_context} <- existing_room_context(meeting, user_id),
         true <- video_module().time_bound_join_urls?(meeting_context),
         {:ok, organizer_url} <- build_join_url(rescheduled, meeting_context, "organizer"),
         {:ok, attendee_url} <- build_join_url(rescheduled, meeting_context, "participant") do
      %{organizer_video_url: organizer_url, attendee_video_url: attendee_url}
    else
      false -> %{}
      {:ok, :none} -> %{}
      {:error, reason} when reason in @quiet_refresh_skips -> %{}
      {:error, reason} -> log_refresh_failure(meeting, reason)
    end
  rescue
    exception -> log_refresh_failure(meeting, exception)
  end

  @doc """
  The join URL for a recipient of this booking that has no personal link:
  its guests, whom the booker invited and who own neither
  `organizer_video_url` nor `attendee_video_url`.

  Built at send time rather than stored. The two per-role links are columns
  on the meeting and a booking has any number of guests, so there is no
  column a guest's link could live in; it is also the one link that is the
  same for every guest, since it names none of them.

  Answers the meeting's own room URL for every provider whose join links are
  plain room addresses, which is what its guests already received, and a
  room-scoped, non-moderator token link on a provider that signs its links
  (see
  `Tymeslot.Integrations.Video.Providers.ProviderBehaviour.shared_join_url/2`).
  A booking with no room answers `nil`.

  It never raises and never fails. A confirmation has to go out whatever the
  video integration is doing, so anything short of a link falls back to the
  room URL, as the provider itself does when minting fails.
  """
  @spec guest_join_url(map()) :: String.t() | nil
  def guest_join_url(meeting) do
    room_url = Map.get(meeting, :meeting_url)

    case Map.get(meeting, :video_room_id) do
      nil -> room_url
      _room_id -> minted_guest_join_url(meeting, room_url)
    end
  end

  # =====================================
  # Private Helper Functions
  # =====================================

  # A room whose organiser or integration is gone, or whose integration was
  # switched off, is skipped without logging, as rebuilding a rescheduled
  # booking's links skips it: nothing is wrong, and the room URL is the link
  # its guests were given before this one existed. Only a provider that
  # answers and still produces no link is worth a warning.
  defp minted_guest_join_url(meeting, room_url) do
    with {:ok, user_id} <- get_meeting_organizer_user_id(meeting),
         {:ok, _provider_type} <- check_video_provider_type(meeting, user_id),
         {:ok, meeting_context} <- existing_room_context(meeting, user_id) do
      provider_guest_link(meeting, meeting_context, room_url)
    else
      _unreachable_room -> room_url
    end
  rescue
    exception -> log_guest_link_failure(meeting, exception, room_url)
  end

  defp provider_guest_link(meeting, meeting_context, room_url) do
    case video_module().shared_join_url(meeting_context, Map.get(meeting, :start_time)) do
      {:ok, join_url} when is_binary(join_url) -> join_url
      {:error, reason} -> log_guest_link_failure(meeting, reason, room_url)
      _no_link -> room_url
    end
  end

  # As in `log_refresh_failure/2`, only the shape of the failure is logged:
  # the reason may carry decrypted credentials or a signed link.
  defp log_guest_link_failure(meeting, reason, room_url) do
    Logger.warning("Could not build the guests' join link, handing out the room URL",
      meeting_id: Map.get(meeting, :id),
      reason: loggable_reason(reason)
    )

    room_url
  end

  defp existing_room_context(meeting, user_id) do
    video_module().existing_room_context(user_id,
      integration_id: meeting.video_integration_id,
      room_id: meeting.video_room_id,
      meeting_url: meeting.meeting_url,
      meeting_id: meeting.id
    )
  end

  # Only the shape of the failure is logged. The context holds the decrypted
  # credentials and a join URL may carry a signed token, so neither the reason
  # term nor an exception's message is safe to render.
  defp log_refresh_failure(meeting, reason) do
    Logger.warning(
      "Could not refresh join links for the new meeting time, keeping the stored ones",
      meeting_id: meeting.id,
      reason: loggable_reason(reason)
    )

    %{}
  end

  defp loggable_reason(reason) when is_atom(reason), do: reason
  defp loggable_reason(%{__exception__: true, __struct__: module}), do: inspect(module)
  defp loggable_reason(_reason), do: :unexpected_error

  defp fetch_meeting(meeting_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> {:ok, meeting}
      {:error, :not_found} -> {:error, :meeting_not_found}
    end
  end

  defp attached_status(%MeetingSchema{video_room_id: nil}), do: :not_attached
  defp attached_status(%MeetingSchema{} = meeting), do: {:already_attached, meeting}

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

  @spec create_provider_meeting_room(MeetingSchema.t(), integer() | nil) ::
          {:ok, MeetingContext.t()} | {:error, term()}
  defp create_provider_meeting_room(meeting, user_id) do
    Logger.info("Requesting video room from provider", meeting_id: meeting.id)

    case video_module().create_meeting_room(user_id,
           integration_id: meeting.video_integration_id,
           meeting_id: meeting.id,
           event_details: EventDetails.from_meeting(meeting)
         ) do
      {:ok, meeting_context} ->
        {:ok, meeting_context}

      {:error, reason} = error ->
        Logger.error("Failed to create video room",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        error
    end
  end

  @spec build_video_room_attrs(MeetingSchema.t(), MeetingContext.t()) ::
          {:ok, map()} | {:error, :incomplete_video_room | :join_url_unavailable}
  defp build_video_room_attrs(meeting, meeting_context) do
    meeting_url = get_meeting_url_from_context(meeting_context)
    room_id = video_module().extract_room_id(meeting_context)

    case {room_id, meeting_url} do
      {nil, nil} -> reject_incomplete_room(meeting, meeting_context)
      _identified -> complete_video_room_attrs(meeting, meeting_context, room_id, meeting_url)
    end
  end

  # A provider that answers successfully but hands back neither a room id nor a
  # meeting URL has given us nothing to join. Refusing it here keeps the booking
  # free of a room that is flagged as enabled but cannot be entered.
  defp reject_incomplete_room(meeting, meeting_context) do
    Logger.error("Video provider returned a room with no identifier or URL",
      meeting_id: meeting.id,
      provider_type: Map.get(meeting_context, :provider_type)
    )

    {:error, :incomplete_video_room}
  end

  @spec complete_video_room_attrs(MeetingSchema.t(), map(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, :join_url_unavailable}
  defp complete_video_room_attrs(meeting, meeting_context, room_id, meeting_url) do
    with {:ok, organizer_url} <- create_secure_join_url(meeting, meeting_context, "organizer"),
         {:ok, attendee_url} <- create_secure_join_url(meeting, meeting_context, "participant") do
      expiry_time = DateTime.add(meeting.end_time, 1800, :second)

      attrs = %{
        meeting_url: meeting_url,
        location: meeting_url,
        video_room_id: room_id,
        video_provider: provider_string(meeting_context.provider_type),
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

  # The provider is stored as its string form so a meeting still knows where its
  # room lives after `video_integration_id` is nulled by the integration's
  # `nilify_all` foreign key. Without it a disconnected integration leaves the
  # room unreachable and it lingers on the organiser's provider account.
  defp provider_string(nil), do: nil

  defp provider_string(provider_type) when is_atom(provider_type),
    do: Atom.to_string(provider_type)

  # The room was created for the integration `meeting` named when it was read,
  # before the provider call. A reschedule can move the meeting to another
  # location while that call is in flight, and attaching the room anyway would
  # hand an in-person meeting a join link. So the integration is re-checked
  # under the lock too, and a room created for a location the meeting has left
  # is released rather than attached.
  @spec persist_video_room(MeetingSchema.t(), map()) ::
          {:ok, MeetingSchema.t()} | {:error, term()}
  defp persist_video_room(
         %MeetingSchema{video_integration_id: integration_id} = meeting,
         video_room_attrs
       ) do
    transaction_result =
      Repo.transaction(fn ->
        case MeetingQueries.get_meeting_for_update(meeting.id) do
          {:ok, locked_meeting} ->
            attach_to_locked(locked_meeting, integration_id, video_room_attrs)

          {:error, :not_found} ->
            Repo.rollback(:meeting_not_found)
        end
      end)

    case transaction_result do
      {:ok, {:attached, updated_meeting}} ->
        # Schedule the calendar update only once we have definitively attached the
        # video room in this call path.
        case CalendarEventScheduler.schedule_calendar_update(updated_meeting.id) do
          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to schedule calendar update after video room attachment",
              meeting_id: updated_meeting.id,
              reason: inspect(reason)
            )
        end

        {:ok, updated_meeting}

      {:ok, {:location_changed, moved_meeting}} ->
        Logger.info("Meeting changed location while its video room was created; releasing it",
          meeting_id: moved_meeting.id
        )

        release_unattached_room(meeting, video_room_attrs)
        {:ok, moved_meeting}

      {:ok, {:already_attached, existing_meeting}} ->
        Logger.info(
          "Video room already attached by a concurrent writer; discarding provider response",
          meeting_id: existing_meeting.id
        )

        {:ok, existing_meeting}

      {:error, reason} = error ->
        # The one place a room id is logged in the clear, deliberately. The
        # write that would have recorded it failed, so the room exists on the
        # provider and nothing in the database points at it: without the id and
        # URL here there is no way to find it again and delete it. Everywhere
        # else the row is reachable by `meeting_id` and the logs carry
        # `room_ref` instead.
        Logger.error("Failed to persist video room attachment",
          meeting_id: meeting.id,
          reason: inspect(reason),
          orphaned_video_room_id: Map.get(video_room_attrs, :video_room_id),
          orphaned_meeting_url: Map.get(video_room_attrs, :meeting_url)
        )

        error
    end
  end

  defp attach_to_locked(
         %MeetingSchema{video_room_id: nil, video_integration_id: integration_id} = locked_meeting,
         integration_id,
         video_room_attrs
       ) do
    case update_meeting_with_video_room(locked_meeting, video_room_attrs) do
      {:ok, updated_meeting} -> {:attached, updated_meeting}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp attach_to_locked(
         %MeetingSchema{video_room_id: nil} = moved_meeting,
         _integration_id,
         _attrs
       ),
       do: {:location_changed, moved_meeting}

  # Another worker won the race; keep the existing attachment.
  defp attach_to_locked(%MeetingSchema{} = already_attached, _integration_id, _attrs),
    do: {:already_attached, already_attached}

  defp release_unattached_room(meeting, %{video_room_id: room_id} = video_room_attrs)
       when is_binary(room_id) do
    room = %{meeting | video_room_id: room_id, video_provider: video_room_attrs.video_provider}

    case VideoSyncWorker.release(room) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue release of an unattached video room",
          meeting_id: meeting.id,
          orphaned_video_room_id: room_id,
          reason: inspect(reason)
        )
    end
  end

  # A provider with no room id (a static custom link) has nothing to delete.
  defp release_unattached_room(_meeting, _video_room_attrs), do: :ok

  @spec update_meeting_with_video_room(MeetingSchema.t(), map()) ::
          {:ok, MeetingSchema.t()} | {:error, :database_update_failed}
  defp update_meeting_with_video_room(meeting, video_room_attrs) do
    case MeetingQueries.update_meeting(meeting, video_room_attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Video room added successfully",
          meeting_id: meeting.id,
          room_ref: Redactor.fingerprint(video_room_attrs.video_room_id)
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

  @spec create_secure_join_url(MeetingSchema.t(), MeetingContext.t(), String.t()) ::
          {:ok, String.t()} | {:error, :join_url_unavailable}
  defp create_secure_join_url(meeting, meeting_context, role) do
    case build_join_url(meeting, meeting_context, role) do
      {:ok, url} ->
        {:ok, url}

      {:error, reason} ->
        # Fall back to the room's own URL on any error
        handle_join_url_error(meeting_context, role, reason)
    end
  end

  defp build_join_url(meeting, meeting_context, role) do
    {participant_name, participant_email} = get_participant_info(meeting, role)

    create_secure_url(
      meeting_context,
      participant_name,
      participant_email,
      role,
      meeting.start_time
    )
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

  # A provider that cannot mint a personalised join URL still leaves the room's
  # own URL behind, so that is what the participant is given. It is the weaker
  # of the two links: a MiroTalk attendee arriving on `meeting_url` lands in the
  # room's lobby and types their own name, rather than arriving already named
  # and carrying a role token. It does open the right room, which matters. A
  # room URL that is not an absolute http(s) address opens nothing at all, so
  # that case fails the attachment instead, leaving the caller free to retry
  # rather than persisting a link the attendee cannot follow.
  @spec handle_join_url_error(MeetingContext.t(), String.t(), term()) ::
          {:ok, String.t()} | {:error, :join_url_unavailable}
  defp handle_join_url_error(%{room_data: %{meeting_url: meeting_url}} = context, role, error) do
    room_ref = Redactor.fingerprint(video_module().extract_room_id(context))

    Logger.error("Failed to create secure join URL",
      room_ref: room_ref,
      role: role,
      error: inspect(error)
    )

    case UrlValidation.validate_http_url(meeting_url) do
      :ok ->
        Logger.warning("Falling back to the room URL for the join link",
          room_ref: room_ref,
          role: role
        )

        {:ok, meeting_url}

      {:error, _message} ->
        Logger.error("Video room has no usable join URL, refusing to attach it",
          room_ref: room_ref,
          role: role
        )

        {:error, :join_url_unavailable}
    end
  end

  # No catch-all clause: `RoomData` enforces both keys, so `MeetingContext.t()`
  # is covered exhaustively here and Dialyzer rejects an unreachable fallback.
  defp get_meeting_url_from_context(%{room_data: %{meeting_url: meeting_url, room_id: room_id}}) do
    meeting_url || room_id
  end

  defp check_video_provider_type(meeting, user_id) do
    integration_result =
      case meeting.video_integration_id do
        nil -> {:error, :not_found}
        id -> Video.fetch_integration_for_user(id, user_id)
      end

    case integration_result do
      {:ok, %{is_active: false}} ->
        {:error, :video_integration_inactive}

      {:ok, integration} ->
        case ProviderConfig.parse(integration.provider) do
          {:ok, provider_type} ->
            {:ok, provider_type}

          {:error, :unknown} ->
            Logger.warning("Unknown video provider type", provider: integration.provider)
            {:error, :unknown_provider}
        end

      {:error, :not_found} ->
        {:error, :video_integration_missing}
    end
  end
end
