defmodule Tymeslot.Workers.VideoTranscoder do
  @moduledoc """
  Oban worker that generates responsive video variants from user-uploaded
  background videos. Produces desktop (WebM + MP4), mobile, and low-quality
  variants with faststart for immediate playback.
  """

  use Oban.Worker,
    queue: :media_processing,
    max_attempts: 3,
    priority: 2

  require Logger

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Repo

  @status_completed "completed"
  @status_failed "failed"

  @spec enqueue(pos_integer(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(theme_customization_id, video_path) do
    cancel_existing_jobs(theme_customization_id)

    %{theme_customization_id: theme_customization_id, video_path: video_path}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"theme_customization_id" => id, "video_path" => video_path}}) do
    if transcoding_enabled?() do
      run_if_available(id, video_path)
    else
      {:cancel, "transcoding disabled"}
    end
  end

  defp run_if_available(id, video_path) do
    transcoder = transcoder_impl()

    if transcoder.available?() do
      run_transcoding(id, video_path, transcoder)
    else
      update_status(id, @status_failed)
      {:cancel, "ffmpeg not available"}
    end
  end

  defp run_transcoding(id, video_path, transcoder) do
    upload_dir = Application.get_env(:tymeslot, :upload_directory, "uploads")
    source_path = Path.join(upload_dir, video_path)
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
        update_status(id, @status_failed)
        Logger.error("Video transcoding failed", theme_customization_id: id, reason: reason)
        {:error, reason}
    end
  end

  defp cancel_existing_jobs(theme_customization_id) do
    Oban.Job
    |> where([j], j.worker == "Tymeslot.Workers.VideoTranscoder")
    |> where([j], j.state in ["available", "scheduled", "retryable"])
    |> where(
      [j],
      fragment("?->>'theme_customization_id' = ?", j.args, ^to_string(theme_customization_id))
    )
    |> Oban.cancel_all_jobs()
  end

  defp update_status(id, status) do
    case Repo.get(ThemeCustomizationSchema, id) do
      nil -> :ok
      record -> record |> Changeset.change(%{video_processing: status}) |> Repo.update()
    end
  end

  defp cleanup_variants(base_path) do
    Enum.each(Transcoder.variant_definitions(), fn %{suffix: suffix} ->
      path = base_path <> suffix
      File.rm(path)
    end)
  end

  defp transcoding_enabled? do
    Application.get_env(:tymeslot, :video_transcoding_enabled, true)
  end

  defp transcoder_impl do
    Application.get_env(:tymeslot, :transcoder, Tymeslot.Media.Transcoder)
  end
end
