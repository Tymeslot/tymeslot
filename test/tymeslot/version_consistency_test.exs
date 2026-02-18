defmodule Tymeslot.VersionConsistencyTest do
  use ExUnit.Case, async: true

  @moduletag :umbrella

  # Navigate from test/tymeslot/ up to the umbrella root
  @umbrella_root Path.expand("../../../../", __DIR__)

  @version_files [
    "mix.exs",
    "apps/tymeslot/mix.exs",
    "apps/tymeslot_saas/mix.exs",
    "CloudronManifest.json",
    "apps/tymeslot/CloudronManifest.json"
  ]

  test "all version files declare the same version" do
    versions =
      Enum.map(@version_files, fn relative_path ->
        path = Path.join(@umbrella_root, relative_path)
        content = File.read!(path)

        version =
          case Regex.run(~r/version[^\d]*(\d+\.\d+\.\d+)/, content, capture: :all_but_first) do
            [v] -> v
            _ -> flunk("Could not extract version from #{relative_path}")
          end

        {relative_path, version}
      end)

    {_, expected} = hd(versions)

    for {path, version} <- versions do
      assert version == expected,
             "Version mismatch in #{path}: found #{version}, expected #{expected}\n" <>
               "Run `mix set_version #{expected}` to sync all files."
    end
  end
end
