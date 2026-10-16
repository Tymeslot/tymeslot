defmodule Tymeslot.Infrastructure.CloudronPackageFreshnessTest do
  @moduledoc """
  Guards the Cloudron App Store package against drifting from this repo.

  Cloudron users do not run the image `Dockerfile.cloudron` builds: the App
  Store installs one Cloudron builds from its own package repository, which
  fetches a release tarball and compiles it with a Dockerfile of its own. When
  that Dockerfile falls behind ours nothing here notices, and its users get a
  toolchain we no longer build or test against, or lose a runtime dependency
  outright (its 2026-09 move to `cloudron/node-base` dropped ffmpeg, which
  silently disabled video backgrounds). Excluded from default runs because it
  needs the network; the nightly `Excluded suites` workflow is what makes it
  bite.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :cloudron_package_freshness

  @package_url "https://git.cloudron.io/packages/tymeslot-app"
  @package_dockerfile_url "#{@package_url}/-/raw/master/Dockerfile"
  @local_dockerfile Path.expand("../../../Dockerfile.cloudron", __DIR__)

  setup_all do
    package = @package_dockerfile_url |> Req.get!(retry: :transient) |> Map.fetch!(:body)
    %{package: package}
  end

  test "the package builds with the same Elixir/OTP image as Dockerfile.cloudron", %{
    package: package
  } do
    ours = @local_dockerfile |> File.read!() |> builder_image()

    assert builder_image(package) == ours,
           "#{@package_url} builds with #{builder_image(package)}; Dockerfile.cloudron " <>
             "builds with #{ours}. Update the package's builder stage to match."
  end

  test "the package installs ffmpeg in its runtime stage", %{package: package} do
    assert runtime_stage(package) =~ ~r/apt-get install[^\n]*\bffmpeg\b/,
           "#{@package_url} no longer installs ffmpeg in its runtime stage, so video " <>
             "background uploads are refused on every Cloudron install."
  end

  defp builder_image(dockerfile) do
    [_line, image] = Regex.run(~r/^FROM\s+(\S+)\s+AS\s+builder\s*$/mi, dockerfile)
    image
  end

  # Everything from the last FROM onwards: the stage the app actually runs in.
  defp runtime_stage(dockerfile) do
    dockerfile |> String.split(~r/^FROM\s/m) |> List.last()
  end
end
