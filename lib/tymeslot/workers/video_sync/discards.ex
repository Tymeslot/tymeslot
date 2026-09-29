defmodule Tymeslot.Workers.VideoSync.Discards do
  @moduledoc """
  The reasons `Tymeslot.Workers.VideoSyncWorker` gives up on a job with, and
  which of them are an expected end of the job rather than a fault.

  Every reason here means the work no longer applies (the room, meeting or
  integration is gone) or only the user can fix it (reconnecting the
  integration), so the worker declares them expected through
  `Tymeslot.Infrastructure.ExpectedJobOutcome`. A discard for a provider
  refusing the change for good goes through `ErrorPolicy.discard_reason/1`
  and is expected only where `ErrorPolicy.expected_discard?/1` says so.
  """

  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Workers.VideoRoom.ErrorPolicy

  require Logger

  @reasons %{
    room_gone: "Calendar event video room not found",
    integration_gone: "Video integration not found",
    no_room: "No provider video room to sync",
    unreachable: "No video integration can reach the provider room",
    scope_insufficient: "Video provider scope insufficient — reconnect required",
    credentials_refused: "Video provider refused the stored credentials: reconnect required"
  }

  @expected_reasons Map.values(@reasons)

  @type key ::
          :room_gone
          | :integration_gone
          | :no_room
          | :unreachable
          | :scope_insufficient
          | :credentials_refused

  @doc "The `{:discard, reason}` for `key`."
  @spec discard(key()) :: {:discard, String.t()}
  def discard(key), do: {:discard, Map.fetch!(@reasons, key)}

  @doc """
  Discards a job whose meeting holds a live provider room that nothing can
  authenticate against: the integration was disconnected and never replaced,
  or the row predates `meetings.video_provider`. Retrying cannot help (only
  the user reconnecting can), so the job is discarded, but loudly. A silent
  `:ok` here is exactly what let orphaned Zoom meetings accumulate unnoticed.
  A released room reaches this only once it has waited out its snoozes.

  Only a fingerprint of the room id goes into the line: the id is the join
  link for every link-based provider, and `meeting_id` already leads to the
  row that holds the real one (or, for a release, to the meeting that did).
  """
  @spec unreachable(map(), String.t(), term()) :: {:discard, String.t()}
  def unreachable(target, action, reason) do
    Logger.warning(
      "Meeting holds a provider video room but no video integration can reach it",
      target.log ++
        [
          action: action,
          provider: target.provider,
          room_ref: Redactor.fingerprint(target.room_id),
          reason: reason
        ]
    )

    discard(:unreachable)
  end

  @doc """
  Whether `reason`, from a job `VideoSyncWorker` discarded, is an expected
  end of the job.
  """
  @spec expected?(term()) :: boolean()
  def expected?(reason), do: reason in @expected_reasons or ErrorPolicy.expected_discard?(reason)
end
