defmodule Tymeslot.Workers.VideoTranscoder do
  @moduledoc """
  Oban worker that generates responsive video variants from a user-uploaded
  video: desktop (WebM + MP4), mobile and low-quality variants, with
  faststart for immediate playback.

  One job per video: its args carry the customisation, the asset field the
  video was uploaded into (`"background_video_path"`) and its path, and the
  job is unique per customisation and field while it waits, so a theme's
  second video gets a job of its own while a replacement upload into the
  same field replaces the waiting job's args. The outcome is recorded under
  the field, and only while the field still holds the job's video
  (`ThemeCustomizationQueries.update_video_processing_status_for/4`).
  """

  use Oban.Worker,
    queue: :media_processing,
    max_attempts: 3,
    priority: 2,
    # `:executing` is left out on purpose: a video replaced while its
    # predecessor encodes gets a job of its own, rather than rewriting the
    # args of a run that would never reread them. The stale run then finds
    # the field has moved on and settles nothing (`settle/2`).
    unique: [
      fields: [:worker, :args],
      keys: [:theme_customization_id, :field],
      states: [:available, :scheduled, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Media.Uploads
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries

  @status_completed "completed"
  @status_failed "failed"

  # Jobs queued before videos were tracked per field carry no field: every
  # one of them was for the background video.
  @legacy_field "background_video_path"

  @doc """
  Queues the transcode of the video `video_path` in the asset field `field`.
  Called inside the transaction that saves the video
  (`ThemeCustomizations.Assets`), so Oban does not retry a failed insert:
  the transaction is already aborted, and the error rolls the save back.
  """
  @spec enqueue(pos_integer(), atom() | String.t(), String.t()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(theme_customization_id, field, video_path) do
    %{
      theme_customization_id: theme_customization_id,
      field: to_string(field),
      video_path: video_path
    }
    |> new(replace: [:args, :scheduled_at])
    |> Oban.insert(retry: false)
  end

  @behaviour ExpectedJobOutcome

  # The upload was removed or replaced before its transcode finished; the
  # current video, if any, has a job of its own. A missing ffmpeg is the
  # operator's to fix, and is recorded.
  @source_gone "Video source no longer present"
  @replaced "Video replaced before its transcode finished"
  @timed_out "Video encode timed out"
  @invalid_path "Invalid video path"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do: reason in [@source_gone, @replaced]

  # Every variant gets its own bound inside the transcoder; this is the
  # backstop for the job as a whole, with room for the status writes and
  # cleanup around the four encodes. Without it Oban lets a job run forever,
  # and the queue runs one job at a time.
  @impl Oban.Worker
  def timeout(_job) do
    length(Transcoder.variant_definitions()) * Transcoder.max_variant_timeout() +
      :timer.minutes(5)
  end

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"theme_customization_id" => id, "video_path" => video_path} = args} =
          job
      ) do
    video = {id, Map.get(args, "field", @legacy_field), video_path}
    transcoder = transcoder_impl()

    if transcoder.available?() do
      run_transcoding(video, transcoder, job)
    else
      settle(video, @status_failed)
      {:cancel, "ffmpeg not available"}
    end
  end

  # Deterministic: no retry can make the path acceptable.
  defp run_transcoding({id, field, video_path} = video, transcoder, job) do
    case Uploads.resolve(video_path) do
      {:ok, source_path} ->
        transcode_variants(video, source_path, transcoder, job)

      {:error, :path_traversal_attempt} ->
        Logger.error("Path traversal attempt detected",
          video_path: video_path,
          theme_customization_id: id,
          field: field
        )

        settle(video, @status_failed)
        {:cancel, @invalid_path}
    end
  end

  defp transcode_variants({id, field, _path} = video, source_path, transcoder, job) do
    base_path = Path.rootname(source_path)

    result =
      Enum.reduce_while(Transcoder.variant_definitions(), :ok, fn variant, :ok ->
        output_path = base_path <> variant.suffix

        case transcoder.transcode(source_path, output_path,
               codec: variant.codec,
               max_height: variant.max_height,
               format: variant.format
             ) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        complete(video, base_path)

      # Retrying cannot bring the bytes back. The status is deliberately not
      # touched: a replacement has its own job, and without one there is no
      # video left to report on.
      {:error, :source_missing} ->
        cleanup_variants(base_path)

        Logger.info("Video source no longer present, cancelling transcode",
          theme_customization_id: id,
          field: field
        )

        {:cancel, @source_gone}

      # The encode ran past a limit already sized generously from the clip's
      # length. Another attempt would take as long and hold the one-at-a-time
      # queue for every other video meanwhile, so the video is failed now.
      {:error, :timeout} ->
        cleanup_variants(base_path)
        settle(video, @status_failed)
        Logger.error("Video transcoding timed out", theme_customization_id: id, field: field)
        {:cancel, @timed_out}

      {:error, reason} ->
        cleanup_variants(base_path)
        handle_failure(video, job, reason)
    end
  end

  # The variants just written belong to this run's video. If the field has
  # moved on to a replacement, they are removed with the video they belong to
  # and the replacement's own job reports its outcome.
  defp complete({id, field, _path} = video, base_path) do
    case settle(video, @status_completed) do
      :ok ->
        Logger.info("Video transcoding completed", theme_customization_id: id, field: field)
        :ok

      {:error, :replaced} ->
        cleanup_variants(base_path)

        Logger.info("Video replaced mid-transcode, discarding its variants",
          theme_customization_id: id,
          field: field
        )

        {:cancel, @replaced}
    end
  end

  defp handle_failure({id, field, _path} = video, job, reason) do
    if job.attempt >= job.max_attempts do
      settle(video, @status_failed)
    end

    Logger.error("Video transcoding failed",
      theme_customization_id: id,
      field: field,
      reason: reason
    )

    {:error, reason}
  end

  defp settle({id, field, video_path}, status) do
    ThemeCustomizationQueries.update_video_processing_status_for(id, field, video_path, status)
  end

  defp cleanup_variants(base_path) do
    Enum.each(Transcoder.variant_definitions(), fn %{suffix: suffix} ->
      File.rm(base_path <> suffix)
    end)
  end

  defp transcoder_impl do
    Application.get_env(:tymeslot, :transcoder, Tymeslot.Media.Transcoder)
  end
end
