defmodule Mix.Tasks.Tymeslot.RefreshHeroicons do
  @moduledoc """
  Refreshes the vendored Heroicons SVGs in `priv/heroicons`.

  The optimised SVGs are committed to the repository rather than pulled from a
  git dep (see `priv/heroicons/README.md` for why). This task fetches a given
  Heroicons release tag, replaces the vendored SVGs, and bumps the version note
  in the README. Run it when upgrading, then commit the resulting diff.

  ## Usage

      mix tymeslot.refresh_heroicons v2.2.0

  Requires `git` on PATH and network access. The tag must exist upstream at
  https://github.com/tailwindlabs/heroicons.
  """

  use Mix.Task

  @shortdoc "Refresh the vendored Heroicons SVGs in priv/heroicons"

  @repo_url "https://github.com/tailwindlabs/heroicons.git"
  @styles ["16", "20", "24"]
  @priv_dir Path.expand("../../../priv/heroicons", __DIR__)

  @impl Mix.Task
  def run([tag]) when is_binary(tag) do
    tmp = Path.join(System.tmp_dir!(), "tymeslot_heroicons_refresh")
    File.rm_rf!(tmp)

    Mix.shell().info("Fetching Heroicons #{tag}…")

    git!([
      "clone",
      "--depth",
      "1",
      "--branch",
      tag,
      "--filter=blob:none",
      "--sparse",
      @repo_url,
      tmp
    ])

    git!(["-C", tmp, "sparse-checkout", "set", "optimized"])

    optimized = Path.join(tmp, "optimized")

    unless File.dir?(optimized) do
      File.rm_rf!(tmp)
      Mix.raise("Heroicons #{tag} has no `optimized/` directory — is the tag correct?")
    end

    replace_styles(optimized)
    copy_license(tmp)
    bump_readme_version(tag)
    File.rm_rf!(tmp)

    count = @priv_dir |> Path.join("**/*.svg") |> Path.wildcard() |> length()
    Mix.shell().info("Refreshed #{count} SVGs to Heroicons #{tag}. Review and commit the diff.")
  end

  def run(_) do
    Mix.raise("Usage: mix tymeslot.refresh_heroicons <tag>  (e.g. v2.2.0)")
  end

  defp replace_styles(optimized) do
    for style <- @styles do
      src = Path.join(optimized, style)
      dest = Path.join(@priv_dir, style)
      File.rm_rf!(dest)
      File.cp_r!(src, dest)
    end
  end

  defp copy_license(tmp) do
    src = Path.join(tmp, "LICENSE")
    if File.exists?(src), do: File.cp!(src, Path.join(@priv_dir, "LICENSE"))
  end

  defp bump_readme_version(tag) do
    readme = Path.join(@priv_dir, "README.md")

    readme
    |> File.read!()
    |> String.replace(~r/Current version: \*\*[^*]+\*\*/, "Current version: **#{tag}**")
    |> then(&File.write!(readme, &1))
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true, env: []) do
      {_, 0} -> :ok
      {out, code} -> Mix.raise("git #{Enum.join(args, " ")} failed (#{code}):\n#{out}")
    end
  end
end
