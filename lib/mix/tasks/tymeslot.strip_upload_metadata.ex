defmodule Mix.Tasks.Tymeslot.StripUploadMetadata do
  @moduledoc """
  Strips location, capture time and device metadata from every image and
  video already in the upload directory.

  A one-off for uploads stored before metadata was stripped on upload; see
  `Tymeslot.Media.UploadMetadataSweep`. Safe to re-run.

  ## Usage

      mix tymeslot.strip_upload_metadata

  In production (packaged release builds, where `mix` is unavailable), run
  the release helper as the user the app runs as:

      bin/tymeslot eval 'Tymeslot.Release.strip_upload_metadata()'
  """

  use Mix.Task

  alias Tymeslot.Release

  @shortdoc "Strip metadata from images and videos already uploaded"

  @impl Mix.Task
  def run(_args) do
    # Only files are touched, so the configuration is all that is needed.
    Mix.Task.run("app.config")

    %{stripped: stripped, unchanged: unchanged, failed: failed} = Release.strip_upload_metadata()

    Mix.shell().info("Stripped #{stripped} file(s); #{unchanged} had no metadata to remove.")

    Enum.each(failed, fn {path, reason} ->
      Mix.shell().error("Could not process #{path}: #{inspect(reason)}")
    end)

    if failed != [], do: Mix.raise("#{length(failed)} file(s) could not be processed.")
  end
end
