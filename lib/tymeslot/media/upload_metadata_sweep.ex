defmodule Tymeslot.Media.UploadMetadataSweep do
  @moduledoc """
  Strips metadata from every image and video already in the upload directory:
  avatars, theme backgrounds and their transcoded variants, and the email logo.

  New uploads are stripped as they are stored. This catches the files stored
  before that was the case, which were published with whatever location,
  capture time and device details they carried. It is a one-off, run with
  `mix tymeslot.strip_upload_metadata` or, from a release,
  `bin/tymeslot eval 'Tymeslot.Release.strip_upload_metadata()'`.

  It is idempotent: an image is re-encoded only while it still carries
  metadata, and a video already stripped is not written to, so it is safe to
  re-run, including after an interruption. Files are found by walking the
  directory rather than by reading the database, so files no row references
  any more are covered too. Symbolic links to files are skipped.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Media.VideoMetadata

  @image_extensions ~w(.jpg .jpeg .png .gif .webp)
  # `.mov` is no longer accepted, but earlier uploads are still served.
  @video_extensions ~w(.mp4 .webm .mov)

  @type report :: %{
          stripped: non_neg_integer(),
          unchanged: non_neg_integer(),
          failed: [{Path.t(), term()}]
        }

  @doc """
  Sweeps `upload_dir`, by default the configured upload directory, and
  reports how many files were stripped, how many had nothing to strip, and
  which could not be processed and why. The same summary is logged, with a
  warning per failed file.
  """
  @spec run(Path.t()) :: report()
  def run(upload_dir \\ Application.get_env(:tymeslot, :upload_directory, "uploads")) do
    upload_dir
    |> media_files()
    |> Enum.reduce(%{stripped: 0, unchanged: 0, failed: []}, fn path, report ->
      case strip(path) do
        {:ok, outcome} -> Map.update!(report, outcome, &(&1 + 1))
        {:error, reason} -> Map.update!(report, :failed, &[{path, reason} | &1])
      end
    end)
    |> Map.update!(:failed, &Enum.reverse/1)
    |> log_report()
  end

  defp log_report(report) do
    Enum.each(report.failed, fn {path, reason} ->
      Logger.warning("Could not strip upload metadata",
        path: path,
        reason: LogFormat.reason(reason)
      )
    end)

    Logger.info("Upload metadata sweep finished",
      stripped: report.stripped,
      unchanged: report.unchanged,
      failed: length(report.failed)
    )

    report
  end

  defp media_files(upload_dir) do
    upload_dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&(media_kind(&1) != nil and regular_file?(&1)))
    |> Enum.sort()
  end

  defp regular_file?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

  defp media_kind(path) do
    extension = path |> Path.extname() |> String.downcase()

    cond do
      extension in @image_extensions -> :image
      extension in @video_extensions -> :video
      true -> nil
    end
  end

  defp strip(path) do
    case media_kind(path) do
      :image -> strip_image(path)
      :video -> VideoMetadata.strip(path)
    end
  end

  defp strip_image(path) do
    case ImageMetadata.metadata?(path) do
      {:ok, true} ->
        with :ok <- ImageMetadata.strip(path, path, Path.extname(path)), do: {:ok, :stripped}

      {:ok, false} ->
        {:ok, :unchanged}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
