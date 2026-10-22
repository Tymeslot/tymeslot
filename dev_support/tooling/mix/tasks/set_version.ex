defmodule Mix.Tasks.SetVersion do
  use Mix.Task

  @shortdoc "Sets the Core version in mix.exs"

  @moduledoc """
  Sets the version string in Core's `mix.exs`.

  Releases are cut in lockstep with a sibling repository: both repositories
  carry the same vX.Y.Z tags, and the workspace `release.sh` runs this task
  here before running the sibling's own `set_version`.

  ## Usage

      mix set_version VERSION

  ## Example

      mix set_version 1.0.0
  """

  @version_file "mix.exs"
  @version_pattern ~r/version: "\d+\.\d+\.\d+"/

  @impl Mix.Task
  def run([version]) do
    unless Regex.match?(~r/^\d+\.\d+\.\d+$/, version) do
      Mix.raise("Invalid version format: #{inspect(version)}. Expected semver like 1.2.3")
    end

    Mix.shell().info("Setting version to #{version}...\n")

    case write_version(Path.join(File.cwd!(), @version_file), version) do
      :updated -> Mix.shell().info("  updated    #{@version_file}")
      :unchanged -> Mix.shell().info("  (unchanged) #{@version_file}")
    end

    Mix.shell().info("\nDone. Next steps:")

    Mix.shell().info(
      "  git add #{@version_file} && git commit -m \"chore: bump version to #{version}\""
    )

    Mix.shell().info("  git tag v#{version}")
  end

  def run(_args) do
    Mix.raise("Usage: mix set_version VERSION")
  end

  @doc """
  Rewrites the first `version: "X.Y.Z"` line of the `mix.exs` at `path`.

  Raises when the file has no such line, so a project file whose layout has
  changed fails the release instead of being skipped silently.

  Public for testing; `run/1` calls it on the current directory's `mix.exs`.
  """
  @spec write_version(Path.t(), String.t()) :: :updated | :unchanged
  def write_version(path, version) do
    original = File.read!(path)

    unless Regex.match?(@version_pattern, original) do
      Mix.raise("No version: \"X.Y.Z\" line found in #{path}")
    end

    case Regex.replace(@version_pattern, original, ~s(version: "#{version}"), global: false) do
      ^original ->
        :unchanged

      updated ->
        File.write!(path, updated)
        :updated
    end
  end
end
