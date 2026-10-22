defmodule Tymeslot.Infrastructure.CloudronPackageFreshnessTest do
  @moduledoc """
  Guards the Cloudron App Store package against drifting from this repo.

  Cloudron users run an image this repository does not build: the App Store
  installs one Cloudron builds from its own package repository, which fetches
  a release tarball and compiles it with a Dockerfile of its own. When that
  Dockerfile falls behind `Dockerfile.docker` nothing here notices, and its
  users get a toolchain we no longer build or test against, or lose a runtime
  dependency outright (its 2026-09 move to `cloudron/node-base` dropped
  ffmpeg, which silently disabled video backgrounds). Excluded from default
  runs because it needs the network; the nightly `Excluded suites` workflow is
  what makes it bite.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :cloudron_package_freshness

  @package_url "https://git.cloudron.io/packages/tymeslot-app"
  @package_dockerfile_url "#{@package_url}/-/raw/master/Dockerfile"
  @local_dockerfile Path.expand("../../../Dockerfile.docker", __DIR__)

  setup_all do
    package = @package_dockerfile_url |> Req.get!(retry: :transient) |> Map.fetch!(:body)
    %{package: package}
  end

  # Only the Elixir and OTP versions are compared. The Debian release in the
  # tag differs on purpose: the package compiles on an older one, so that the
  # release runs on Cloudron's base image.
  test "the package builds with the same Elixir and OTP as Dockerfile.docker", %{
    package: package
  } do
    ours = @local_dockerfile |> File.read!() |> toolchain()

    assert toolchain(package) == ours,
           "#{@package_url} builds with Elixir/OTP #{inspect(toolchain(package))}; " <>
             "Dockerfile.docker builds with #{inspect(ours)}. Update the package's " <>
             "builder stage to match."
  end

  test "the package installs ffmpeg in its runtime stage", %{package: package} do
    assert runtime_stage(package) =~ ~r/apt-get install[^\n]*\bffmpeg\b/,
           "#{@package_url} no longer installs ffmpeg in its runtime stage, so video " <>
             "background uploads are refused on every Cloudron install."
  end

  # The `{elixir, otp}` versions of the first `hexpm/elixir` image, the stage
  # that compiles the release.
  defp toolchain(dockerfile) do
    [_line, elixir, otp] =
      Regex.run(~r/^FROM\s+hexpm\/elixir:(\d+\.\d+\.\d+)-erlang-([\d.]+)-/m, dockerfile)

    {elixir, otp}
  end

  # Everything from the last FROM onwards: the stage the app actually runs in.
  defp runtime_stage(dockerfile) do
    dockerfile |> String.split(~r/^FROM\s/m) |> List.last()
  end
end
