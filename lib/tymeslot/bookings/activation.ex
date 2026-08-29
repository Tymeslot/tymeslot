defmodule Tymeslot.Bookings.Activation do
  @moduledoc """
  Turning a confirmed meeting into a booking the world knows about.

  Two paths arrive at the same point. A booking on an ordinary meeting type is
  confirmed the moment it is created; a booking on a meeting type requiring
  manual approval is confirmed later, when the host says yes. From that point
  on the work is identical: create the video room if the meeting has a
  provider, then send the confirmation emails and fan out to webhooks,
  Telegram and Slack.

  It lives in its own module so the two paths cannot drift. The ordering
  matters and is easy to get wrong from a second call site: the video room is
  created *before* the emails so the join link is in the confirmation the
  attendee receives, rather than arriving in a later correction. Where a
  provider is configured, that means handing both steps to
  `Tymeslot.Workers.VideoRoomWorker`, which sends the emails itself once the
  room exists — and falls back to sending them without a link if the provider
  is unreachable, so a broken video integration never costs the attendee their
  confirmation.
  """

  require Logger

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.VideoRoomWorker

  # Providers whose rooms Tymeslot creates through an API call, and which
  # therefore need the video job to run before the confirmation email is
  # composed. This is every provider `Video` knows about except `:none` (no
  # integration configured, so there is nothing to create) — currently
  # `ProviderConfig`'s `@providers`, restated here rather than pulled from
  # `ProviderConfig.all_providers/0` because that list is toggle-filtered: an
  # integration a host already connected before its provider was disabled
  # must still get its room created, not silently skip straight to `notify/1`.
  @api_created_providers [:mirotalk, :google_meet, :teams, :zoom, :custom]

  @doc """
  Runs the side effects a newly created or newly confirmed meeting needs.

  A meeting still awaiting the host's approval takes the request fan-out; any
  other status takes the confirmation one.

  With `with_video_room: true` the caller asserts the booking flow wants a
  room whenever the meeting has an integration; without it, the provider is
  auto-detected and only the API-backed ones defer the emails.

  Always returns `:ok`. Every failure here is recoverable and separately
  retried — the meeting itself is already committed, and refusing to return
  success would only invite callers to roll back a booking that exists.
  """
  @spec activate(Meeting.t(), keyword()) :: :ok
  def activate(meeting, opts \\ [])

  # A booking still held for the host to approve is not a booking anyone has
  # agreed to, so none of the confirmation work runs. Branching here rather
  # than at each call site means no future caller can accidentally send a
  # confirmation for a meeting the host has not accepted;
  # `Tymeslot.Meetings.Approval` calls back in once it has confirmed.
  #
  # The request still has to reach people — the invitee needs telling their
  # booking is not final, and the host cannot approve what they never heard
  # about — so it takes the request fan-out instead.
  def activate(%Meeting{status: "awaiting_approval"} = meeting, _opts) do
    case Events.meeting_requested(meeting) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule booking request emails",
          meeting_id: meeting.id,
          error: inspect(reason)
        )

        :ok
    end
  end

  def activate(%Meeting{} = meeting, opts) do
    if wants_video_room?(meeting, opts) do
      schedule_video_room_with_announcement(meeting)
    else
      notify(meeting)
    end
  end

  defp wants_video_room?(meeting, opts) do
    if Keyword.get(opts, :with_video_room, false) do
      not is_nil(meeting.video_integration_id)
    else
      match?({:ok, provider} when provider in @api_created_providers, video_provider_for(meeting))
    end
  end

  defp schedule_video_room_with_announcement(meeting) do
    case VideoRoomWorker.schedule_video_room_creation_with_announcement(meeting.id) do
      :ok -> :ok
      {:error, _reason} -> notify(meeting)
    end
  end

  defp notify(meeting) do
    case Events.meeting_created(meeting) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule confirmation emails for meeting",
          meeting_id: meeting.id,
          error: inspect(reason)
        )

        :ok
    end
  end

  defp video_provider_for(%Meeting{video_integration_id: nil}), do: {:error, :not_found}

  defp video_provider_for(%Meeting{} = meeting) do
    with {:ok, integration} <-
           Video.fetch_integration_for_user(
             meeting.video_integration_id,
             meeting.organizer_user_id
           ) do
      {:ok, parse_provider(integration, meeting)}
    end
  end

  defp parse_provider(integration, meeting) do
    case VideoProviderConfig.parse_known(integration.provider) do
      {:ok, provider} ->
        provider

      {:error, :unknown} ->
        Logger.warning("Video integration has an unrecognised provider",
          video_integration_id: meeting.video_integration_id,
          provider: integration.provider
        )

        :none
    end
  end
end
