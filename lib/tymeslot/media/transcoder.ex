defmodule Tymeslot.Media.Transcoder do
  @moduledoc """
  Production video transcoder using ffmpeg.
  Generates responsive variants from uploaded video files.
  """

  @behaviour Tymeslot.Media.TranscoderBehaviour

  require Logger

  # How much of a failed run's ffmpeg output to keep in the log.
  @error_excerpt_chars 500

  @variant_definitions [
    %{
      suffix: "-desktop.webm",
      format: "webm",
      max_height: 1080,
      codec: "libvpx-vp9",
      type: "video/webm",
      media: "(min-width: 1024px)"
    },
    %{
      suffix: "-desktop.mp4",
      format: "mp4",
      max_height: 1080,
      codec: "libx264",
      type: "video/mp4",
      media: "(min-width: 1024px)"
    },
    %{
      suffix: "-mobile.mp4",
      format: "mp4",
      max_height: 720,
      codec: "libx264",
      type: "video/mp4",
      media: "(max-width: 1023px)"
    },
    %{
      suffix: "-low.mp4",
      format: "mp4",
      max_height: 480,
      codec: "libx264",
      type: "video/mp4",
      media: "(max-width: 480px)"
    }
  ]

  @spec variant_definitions() :: [map()]
  def variant_definitions, do: @variant_definitions

  @spec derive_variant_paths(String.t()) :: [String.t()]
  def derive_variant_paths(original_path) do
    base = Path.rootname(original_path)
    Enum.map(@variant_definitions, fn %{suffix: suffix} -> base <> suffix end)
  end

  @impl Tymeslot.Media.TranscoderBehaviour
  def available? do
    System.find_executable("ffmpeg") != nil
  end

  @impl Tymeslot.Media.TranscoderBehaviour
  def transcode(source_path, output_path, opts) do
    if File.exists?(source_path) do
      run_ffmpeg(source_path, output_path, opts)
    else
      {:error, :source_missing}
    end
  end

  defp run_ffmpeg(source_path, output_path, opts) do
    codec = Keyword.fetch!(opts, :codec)
    max_height = Keyword.fetch!(opts, :max_height)
    format = Keyword.fetch!(opts, :format)

    args = build_ffmpeg_args(source_path, output_path, codec, max_height, format)

    case System.cmd("ffmpeg", args, stderr_to_stdout: true, env: []) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        transcode_failure(source_path, output_path, output, exit_code)
    end
  end

  # A background video the owner replaces mid-encode is deleted underneath the
  # running job, and ffmpeg reports that as a plain non-zero exit like any other
  # error. Re-checking the source separates "the user moved on" — which no retry
  # can fix and which nobody should be alerted about — from a genuine encode
  # failure.
  defp transcode_failure(source_path, output_path, output, exit_code) do
    if File.exists?(source_path) do
      Logger.error("ffmpeg transcode failed",
        exit_code: exit_code,
        source: source_path,
        output_path: output_path,
        ffmpeg_output: ffmpeg_error_excerpt(output)
      )

      {:error, "ffmpeg exited with status #{exit_code}"}
    else
      Logger.info("Video source removed while transcoding, abandoning variant",
        source: source_path,
        output_path: output_path
      )

      {:error, :source_missing}
    end
  end

  # ffmpeg opens with its version banner and the whole `./configure` line, so
  # the first bytes of a failed run say nothing about why it failed. The reason
  # is always the last thing written.
  defp ffmpeg_error_excerpt(output) do
    output
    |> String.trim_trailing()
    |> String.slice(-@error_excerpt_chars, @error_excerpt_chars)
  end

  defp build_ffmpeg_args(source, output, codec, max_height, format) do
    base_args = ["-i", source, "-y", "-an"]

    codec_args =
      case format do
        "webm" ->
          ["-c:v", codec, "-b:v", "1M", "-crf", "30"]

        "mp4" ->
          ["-c:v", codec, "-preset", "medium", "-crf", "23", "-movflags", "+faststart"]
      end

    scale_args = ["-vf", "scale=-2:'min(#{max_height},ih)'"]

    base_args ++ codec_args ++ scale_args ++ [output]
  end
end
