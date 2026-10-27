defmodule Mix.Tasks.Gettext.Check do
  @shortdoc "Checks the .pot catalogues against source, skipping the run when nothing can have changed"

  @moduledoc """
  `mix gettext.extract --check-up-to-date`, but only when it can say something
  new.

      $ mix gettext.check
      $ mix gettext.check --force    # extract regardless of the cache

  Extraction is a compiler pass, so the check force-recompiles the whole
  project: measured here, 89s in Core and 56s in the repo that consumes it,
  against about 50s for the forced compile alone. That is two and a half
  minutes of `./mix.sh precommit` spent, most runs, confirming what the
  previous run already confirmed.

  This task records a digest of every input that can change the extractor's
  output (see `Tymeslot.GettextCheck.Fingerprint`) after a passing run, and
  skips the next run while the digest still matches. A change to a file that
  cannot carry a translatable string, which is most of the tree, no longer
  costs anything; a change to one that can still pays the full price.

  The digest lives in the build's manifest directory, so `mix clean` discards
  it and the next run extracts for real.

  ## Why it shells out

  `Mix.Task.run("gettext.extract", …)` would recompile this very module while
  this function is running on it. One reload is survivable, a second purges the
  old code and takes the process with it, and the extract task issues two
  compile calls to cover an older Elixir. A subprocess costs a Mix boot on the
  path that was about to spend a minute compiling anyway, and cannot be
  surprised by that.

  ## What it is not

  It is a local convenience. Both repositories' CI run
  `mix gettext.extract --check-up-to-date` directly, with no digest and no
  skip, so a catalogue can never reach a release stale because a cache said
  otherwise.
  """

  use Mix.Task

  alias Mix.Project
  alias Tymeslot.GettextCheck.Fingerprint

  @switches [force: :boolean]
  @manifest "gettext_check.manifest"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    root = File.cwd!()
    fingerprint = Fingerprint.compute(root, source_dirs: Project.config()[:elixirc_paths])
    manifest = Path.join(Project.manifest_path(), @manifest)

    if not Keyword.get(opts, :force, false) and File.read(manifest) == {:ok, fingerprint} do
      Mix.shell().info([
        :faint,
        "Catalogues were checked against this source tree already, and nothing that ",
        "can change extraction has moved since. Run with --force to extract anyway.",
        :reset
      ])
    else
      # Dropped before the run rather than after it, so an extraction that is
      # interrupted rather than failed cannot leave a pass recorded for a tree
      # it never finished reading.
      File.rm(manifest)
      extract!()
      File.mkdir_p!(Path.dirname(manifest))
      File.write!(manifest, fingerprint)
    end
  end

  defp extract! do
    {_output, code} =
      System.cmd("mix", ["gettext.extract", "--check-up-to-date"],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        # Overrides nothing: the subprocess has to extract under the same
        # MIX_ENV as the manifest it is about to justify, and that is exactly
        # what inheriting the environment gives it.
        env: []
      )

    if code != 0, do: exit({:shutdown, code})
  end
end
