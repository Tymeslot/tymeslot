defmodule Tymeslot.Media.Transcoder do
  @moduledoc """
  Production video transcoder using ffmpeg.
  Generates responsive variants from uploaded video files.
  """

  @behaviour Tymeslot.Media.TranscoderBehaviour

  require Logger

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
    codec = Keyword.fetch!(opts, :codec)
    max_height = Keyword.fetch!(opts, :max_height)
    format = Keyword.fetch!(opts, :format)

    args = build_ffmpeg_args(source_path, output_path, codec, max_height, format)

    case System.cmd("ffmpeg", args, stderr_to_stdout: true, env: []) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        Logger.error("ffmpeg transcode failed",
          exit_code: exit_code,
          source: source_path,
          output_path: output_path,
          ffmpeg_output: String.slice(output, 0, 500)
        )

        {:error, "ffmpeg exited with status #{exit_code}"}
    end
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
