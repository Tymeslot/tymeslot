defmodule Tymeslot.Workers.VideoTranscoder do
  @moduledoc """
  Oban worker that generates responsive video variants from user-uploaded
  background videos. Produces desktop (WebM + MP4), mobile, and low-quality
  variants with faststart for immediate playback.
  """

  use Oban.Worker,
    queue: :media_processing,
    max_attempts: 3,
    priority: 2,
    unique: [
      fields: [:worker, :args],
      keys: [:theme_customization_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Media.Transcoder
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries

  @status_completed "completed"
  @status_failed "failed"

  @spec enqueue(pos_integer(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(theme_customization_id, video_path) do
    %{theme_customization_id: theme_customization_id, video_path: video_path}
    |> new(replace: [:args, :scheduled_at])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"theme_customization_id" => id, "video_path" => video_path}} = job
      ) do
    transcoder = transcoder_impl()

    if transcoder.available?() do
      run_transcoding(id, video_path, transcoder, job)
    else
      update_status(id, @status_failed)
      {:cancel, "ffmpeg not available"}
    end
  end

  defp run_transcoding(id, video_path, transcoder, job) do
    upload_dir = Application.get_env(:tymeslot, :upload_directory, "uploads")
    source_path = Path.join(upload_dir, video_path)

    if path_within_directory?(source_path, upload_dir) do
      transcode_variants(id, source_path, transcoder, job)
    else
      Logger.error("Path traversal attempt detected", video_path: video_path)
      update_status(id, @status_failed)
      {:error, "Invalid video path"}
    end
  end

  defp transcode_variants(id, source_path, transcoder, job) do
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
        update_status(id, @status_completed)
        Logger.info("Video transcoding completed", theme_customization_id: id)
        :ok

      # The source was replaced or removed while this job was queued or running.
      # Retrying cannot bring the bytes back, and the status is deliberately not
      # touched: the current video's fate belongs to whichever run owns it now,
      # and marking it `failed` here would report the old video's fate against
      # the new one.
      {:error, :source_missing} ->
        cleanup_variants(base_path)
        handle_missing_source(id, job)

      {:error, reason} ->
        cleanup_variants(base_path)

        if job.attempt >= job.max_attempts do
          update_status(id, @status_failed)
        end

        Logger.error("Video transcoding failed", theme_customization_id: id, reason: reason)
        {:error, reason}
    end
  end

  # A replacement uploaded while this job was executing could not insert a job
  # of its own: uniqueness matched this row and `replace: [:args]` rewrote its
  # args instead, which this running process never rereads. Check the row now;
  # if the path has moved on, snooze so the next run picks the replacement up
  # rather than letting it die with a cancelled job.
  defp handle_missing_source(id, %Oban.Job{args: %{"video_path" => ran_path}} = job) do
    case ObanJobQueries.get_current_args(job) do
      %{"video_path" => current_path} when current_path != ran_path ->
        Logger.info("Video source replaced mid-transcode, rerunning for the replacement",
          theme_customization_id: id
        )

        {:snooze, 1}

      _unchanged_or_gone ->
        Logger.info("Video source no longer present, cancelling transcode",
          theme_customization_id: id
        )

        {:cancel, "Video source no longer present"}
    end
  end

  defp update_status(id, status) do
    case ThemeCustomizationQueries.update_video_processing_status(id, status) do
      :ok ->
        :ok

      {:error, :status_update_failed} ->
        Logger.warning("Failed to update video processing status",
          theme_customization_id: id,
          status: status
        )

        {:error, :status_update_failed}
    end
  end

  defp cleanup_variants(base_path) do
    Enum.each(Transcoder.variant_definitions(), fn %{suffix: suffix} ->
      path = base_path <> suffix
      File.rm(path)
    end)
  end

  defp transcoder_impl do
    Application.get_env(:tymeslot, :transcoder, Tymeslot.Media.Transcoder)
  end

  defp path_within_directory?(path, directory) do
    expanded_path = Path.expand(path)
    expanded_dir = Path.expand(directory)

    within_dir? = String.starts_with?(expanded_path, expanded_dir <> "/")
    not_symlink? = not symlink?(expanded_path)

    within_dir? and not_symlink?
  end

  defp symlink?(path) do
    match?({:ok, %{type: :symlink}}, File.lstat(path))
  end
end
