defmodule Mix.Tasks.Actionlint do
  @shortdoc "Lints the CI workflow files, including their embedded shell"

  @moduledoc """
  Runs actionlint over this repository's CI workflow files.

      $ mix actionlint

  The value is less in the YAML schema check than in shellcheck, which
  actionlint runs over every embedded `run:` block. Those blocks are the only
  shell in either repository that nothing else in the gate covers.

  Both workflow directories are linted where they exist, so the one task serves
  Core (`.github/workflows`) and the overlay (`.gitea/workflows`) alike.

  ## Why a missing binary is not a failure

  actionlint is an external binary rather than a Mix dependency, so a checkout
  without it would otherwise fail the whole gate on a tool nobody asked for.
  The task says loudly that it skipped instead, on the same reasoning as
  `.githooks/pre-commit`: a gate that disappears silently is worse than no
  gate, because it still reads as coverage. CI installs a pinned, checksummed
  binary, so the check is enforced there regardless.
  """

  use Mix.Task

  @workflow_dirs [".github/workflows", ".gitea/workflows"]
  @install_url "https://github.com/rhysd/actionlint/releases"

  @impl Mix.Task
  def run(_argv) do
    lint(workflow_files(), System.find_executable("actionlint"))
  end

  defp lint([], _binary) do
    Mix.shell().info("actionlint: no workflow files in this repository, nothing to lint.")
  end

  defp lint(_files, nil) do
    Mix.shell().error("""
    actionlint: not installed, so the workflow lint was SKIPPED.
    actionlint: install it from #{@install_url} to enable this gate.\
    """)
  end

  defp lint(files, binary) do
    {_output, status} =
      System.cmd(binary, ["-color" | files],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        # A workflow linter reads files and needs nothing from the environment,
        # so it is handed no variables of ours to leak into its output.
        env: []
      )

    if status != 0, do: exit({:shutdown, status})
  end

  defp workflow_files do
    Enum.flat_map(@workflow_dirs, fn dir ->
      Path.wildcard(Path.join(dir, "*.{yml,yaml}"))
    end)
  end
end
