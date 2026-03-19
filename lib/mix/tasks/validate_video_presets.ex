defmodule Mix.Tasks.Tymeslot.ValidateVideoPresets do
  @moduledoc """
  Validates that all preset MP4 video files have the moov atom before mdat,
  ensuring fast-start playback. Requires ffprobe to be installed locally.

  ## Usage

      mix tymeslot.validate_video_presets
  """

  use Mix.Task

  @shortdoc "Validates preset video files have faststart (moov before mdat)"

  @video_dir "apps/tymeslot/priv/static/videos/backgrounds"

  @impl Mix.Task
  def run(_args) do
    unless System.find_executable("ffprobe") do
      Mix.raise("ffprobe not found. Install ffmpeg to use this task.")
    end

    mp4_files =
      @video_dir
      |> Path.join("*.mp4")
      |> Path.wildcard()
      |> Enum.reject(&Regex.match?(~r/-[0-9a-f]{32}\.mp4$/, &1))
      |> Enum.sort()

    if mp4_files == [] do
      Mix.raise("No MP4 files found in #{@video_dir}")
    end

    broken =
      Enum.filter(mp4_files, fn file ->
        {output, 0} = System.cmd("ffprobe", ["-v", "trace", file], stderr_to_stdout: true)

        atoms =
          output
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "parent:'root'"))
          |> Enum.filter(fn line ->
            String.contains?(line, "type:'moov'") or String.contains?(line, "type:'mdat'")
          end)

        case atoms do
          [first | _] -> String.contains?(first, "mdat")
          _ -> false
        end
      end)

    if broken == [] do
      Mix.shell().info(
        "All #{length(mp4_files)} preset MP4 files have faststart (moov before mdat)."
      )
    else
      Mix.shell().error("The following files have moov AFTER mdat (missing faststart):")

      Enum.each(broken, fn file ->
        Mix.shell().error("  #{file}")
      end)

      Mix.raise("Fix with: ffmpeg -i input.mp4 -movflags faststart -c copy output.mp4")
    end
  end
end
