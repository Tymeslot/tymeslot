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
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

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

      {:error, reason} ->
        cleanup_variants(base_path)

        if job.attempt >= job.max_attempts do
          update_status(id, @status_failed)
        end

        Logger.error("Video transcoding failed", theme_customization_id: id, reason: reason)
        {:error, reason}
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
