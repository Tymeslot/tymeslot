defmodule Tymeslot.GettextCheck.Fingerprint do
  @moduledoc """
  A digest of everything that can change what `mix gettext.extract` produces.

  `mix gettext.check` records this after a passing extraction and skips the
  next one while it still matches. The digest is therefore a claim: if it has
  not moved, the `.pot` catalogues that were up to date last time are still up
  to date now.

  ## What goes in

  * **Source files that mention gettext.** Every file under the project's
    `elixirc_paths` with a compiled extension, kept only if its contents match
    `#{inspect(~r/gettext/i)}`. The path is hashed alongside the contents, so
    adding, renaming or deleting one of these files moves the digest even when
    no line of any surviving file changed.
  * **The `.pot` catalogues themselves.** The check compares source against
    them, so editing one by hand is a change in the input, not only in the
    answer.
  * **`mix.exs`, `mix.lock` and `config/**.exs`.** The `:gettext` project
    options decide how a template is written, the backend's configuration
    decides which domains exist, and the lock pins the extractor itself.

  ## Why the marker filter is safe

  A file can only contribute a message by expanding a gettext macro with the
  message as a literal, and reaching those macros takes `use Gettext`, an
  `import`, or a fully qualified call. All three spell "gettext" in the file
  that holds the string, so a file without the marker cannot produce, move or
  remove a message. That is what buys the skip: roughly two thirds of the tree
  is outside the set, and editing any of it cannot make a catalogue stale.

  The one construct that would break the argument is a project-local macro that
  expands to a gettext call, letting a caller carry the literal without the
  word: `defmacro t(msgid), do: quote(do: gettext(unquote(msgid)))`. Nothing in
  either repository does this, and it would be a bad idea for the same reason
  extraction cannot follow it. If one is ever added, hash the whole tree
  instead of filtering: correctness first, the two thirds second.

  Both repositories' CI run `mix gettext.extract --check-up-to-date` unfiltered
  and uncached, so the skip is a local convenience with a backstop, never the
  only thing standing between a stale catalogue and a release.
  """

  # Bump when the rule above changes, so caches written under the old rule are
  # not honoured under the new one.
  @rule_version 1

  @extensions ~w[.ex .exs .eex .heex]
  @marker ~r/gettext/i

  @doc """
  Returns the hex-encoded digest for the project rooted at `root`.

  Options:

    * `:source_dirs` - directories to scan, relative to `root`
      (default: `["lib"]`, normally the project's `elixirc_paths`)
    * `:pot_dir` - where the catalogues live (default: `"priv/gettext"`)
  """
  @spec compute(Path.t(), keyword()) :: String.t()
  def compute(root, opts \\ []) do
    source_dirs = Keyword.get(opts, :source_dirs, ["lib"])
    pot_dir = Keyword.get(opts, :pot_dir, "priv/gettext")

    lines =
      root
      |> entries(source_dirs, pot_dir)
      |> Enum.map(fn {path, contents} -> [path, " ", hex(contents), "\n"] end)
      |> Enum.sort()

    hex([Integer.to_string(@rule_version), "\n" | lines])
  end

  defp entries(root, source_dirs, pot_dir) do
    marked_sources(root, source_dirs) ++
      read_all(root, catalogues(root, pot_dir) ++ settings(root))
  end

  # The contents are needed to hash the file anyway, so the marker is applied to
  # what was already read rather than costing a second pass over the tree.
  defp marked_sources(root, source_dirs) do
    root
    |> read_all(sources(root, source_dirs))
    |> Enum.filter(fn {_path, contents} -> contents =~ @marker end)
  end

  defp sources(root, source_dirs) do
    extensions = Enum.map_join(@extensions, ",", &String.trim_leading(&1, "."))

    Enum.flat_map(source_dirs, fn dir ->
      Path.wildcard(Path.join([root, dir, "**/*.{#{extensions}}"]))
    end)
  end

  defp catalogues(root, pot_dir), do: Path.wildcard(Path.join([root, pot_dir, "**/*.pot"]))

  defp settings(root) do
    ["mix.exs", "mix.lock"]
    |> Enum.map(&Path.join(root, &1))
    |> Enum.concat(Path.wildcard(Path.join([root, "config", "**/*.exs"])))
  end

  # A path that has gone missing since the wildcard ran is simply left out: the
  # set of paths is itself hashed, so its absence is already a change.
  defp read_all(root, paths) do
    for path <- paths, {:ok, contents} <- [File.read(path)] do
      {Path.relative_to(path, root), contents}
    end
  end

  defp hex(iodata), do: :sha256 |> :crypto.hash(iodata) |> Base.encode16(case: :lower)
end
