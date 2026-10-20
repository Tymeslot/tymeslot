defmodule Mix.Tasks.Gettext.MoveDomain do
  @shortdoc "Moves the strings of some source files into another gettext domain, keeping their translations"

  @moduledoc """
  Splits a catalogue: points every gettext call in the given files at another
  domain, re-extracts, and carries each locale's existing translations across.

      $ mix gettext.move_domain booking booking_errors lib/tymeslot_web/live/scheduling/handlers
      $ mix gettext.move_domain FROM TO PATH... [--priv priv/gettext]

  A `PATH` is a file, a directory (every `.ex`, `.exs` and `.heex` below it) or
  a wildcard. The target domain may be new or existing.

  In order, it

    1. snapshots every locale's translations of both domains,
    2. rewrites the domain argument of each `d*gettext` call (and its `_noop`
       form, and `Gettext.d*gettext/3,4` runtime lookups) in the moving files,
    3. runs `mix gettext.extract --merge` in a subprocess (see
       `Mix.Tasks.Gettext.Check` for why not in-process),
    4. fills every empty or fuzzy entry in the target domain's `.po` files
       from the snapshot,
    5. lists anything still untranslated, and every remaining `"FROM"` literal
       under `lib/`: a domain stored in a map or attribute and looked up later,
       which must be checked by hand.

  It does not touch the Credo domain allowlists or the translation skill's
  domain table; the closing report says so.
  """

  use Mix.Task

  alias Expo.PO
  alias Tymeslot.GettextCheck.DomainMove

  @switches [priv: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)
    priv = Keyword.get(opts, :priv, "priv/gettext")

    {from, to, paths} =
      case args do
        [from, to | [_first | _rest] = paths] when from != to -> {from, to, paths}
        _other -> Mix.raise("Usage: mix gettext.move_domain FROM TO PATH... [--priv DIR]")
      end

    if not File.exists?(Path.join(priv, from <> ".pot")),
      do: Mix.raise("No catalogue for domain #{inspect(from)} in #{priv}")

    snapshot = DomainMove.snapshot(priv, [from, to])
    rewrite!(paths, from, to)
    extract!()
    untranslated = DomainMove.carry(priv, to, snapshot)

    report(priv, from, to, untranslated)
  end

  defp rewrite!(paths, from, to) do
    files = Enum.flat_map(paths, &expand/1)
    if files == [], do: Mix.raise("No source files match #{Enum.join(paths, " ")}")

    total =
      Enum.reduce(files, 0, fn file, total ->
        {source, count} = file |> File.read!() |> DomainMove.rewrite_source(from, to)
        if count > 0, do: File.write!(file, source)
        total + count
      end)

    if total == 0, do: Mix.raise("No #{inspect(from)} gettext calls in the given paths")
    Mix.shell().info("Rewrote #{total} call(s) in #{length(files)} file(s) to #{inspect(to)}")
  end

  defp expand(path) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,exs,heex}"))
      true -> Path.wildcard(path)
    end
  end

  defp extract! do
    {_output, code} =
      System.cmd("mix", ["gettext.extract", "--merge"],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: []
      )

    if code != 0, do: Mix.raise("mix gettext.extract --merge failed (exit #{code})")
  end

  defp report(priv, from, to, untranslated) do
    shell = Mix.shell()
    shell.info("#{from}: #{count(priv, from)} messages; #{to}: #{count(priv, to)} messages")

    for {locale, keys} <- untranslated, keys != [] do
      shell.error("#{locale}/#{to}.po: #{length(keys)} untranslated: #{inspect(keys)}")
    end

    references =
      for file <- Path.wildcard("lib/**/*.{ex,exs,heex}"),
          {line, text} <- DomainMove.runtime_references(File.read!(file), from),
          do: "  #{file}:#{line}: #{text}"

    if references != [] do
      shell.info("Remaining #{inspect(from)} literals; check each is not a moved lookup:")
      Enum.each(references, &shell.info/1)
    end

    shell.info(
      "Next: add #{inspect(to)} to both Credo domain allowlists if it is new, " <>
        "and update the domain table in the tymeslot-translations skill."
    )
  end

  defp count(priv, domain) do
    path = Path.join(priv, domain <> ".pot")
    if File.exists?(path), do: length(PO.parse_file!(path).messages), else: 0
  end
end
