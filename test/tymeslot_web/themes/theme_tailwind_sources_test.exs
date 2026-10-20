defmodule TymeslotWeb.Themes.ThemeTailwindSourcesTest do
  @moduledoc """
  Guards the `@source` list in `assets/css/scheduling/shared/entry.css`.

  The theme bundles scan only the theme tree and the web-layer files a booking
  page reaches, so a component a theme starts to call from elsewhere in the
  web layer would lose its utility classes without any build error. This walks
  the compiled theme modules and everything they reach inside the web layer,
  following remote calls and every web-layer module named as a value (a
  `module={...}` attribute, an `apply/3`, a `{module, fun}` tuple), and fails
  for any source file, or `.heex` template the module records as an external
  resource, that the list leaves out.
  """

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  @entry_css "assets/css/scheduling/shared/entry.css"

  # Reached from theme code without rendering anything of their own; following
  # them would pull in the whole web layer. `AuthLive` is named only as a value
  # in `Layouts`' list of credential-bearing views, never rendered by a booking
  # page.
  @not_followed [
    TymeslotWeb.Router,
    TymeslotWeb.Endpoint,
    TymeslotWeb.Gettext,
    TymeslotWeb.AuthLive
  ]

  test "every web-layer file a booking page reaches is a Tailwind source" do
    sources = tailwind_sources()

    missing =
      reachable_sources()
      |> Enum.reject(&covered?(&1, sources))
      |> Enum.sort()

    assert missing == [],
           "Add these to the @source list in #{@entry_css}:\n" <>
             Enum.map_join(missing, "\n", &Path.relative_to_cwd/1)
  end

  defp tailwind_sources do
    dir = Path.dirname(@entry_css)

    ~r/^@source "([^"]+)";/m
    |> Regex.scan(File.read!(@entry_css), capture: :all_but_first)
    |> Enum.map(fn [path] -> dir |> Path.join(path) |> Path.expand() end)
  end

  defp covered?(file, sources) do
    Enum.any?(sources, &(file == &1 or String.starts_with?(file, &1 <> "/")))
  end

  defp reachable_sources do
    {:ok, modules} = :application.get_key(:tymeslot, :modules)
    web = Map.new(for module <- modules, source = web_source(module), do: {module, source})

    roots =
      for {module, source} <- web,
          String.contains?(source, "/lib/tymeslot_web/themes/"),
          do: module

    web
    |> walk([TymeslotWeb.Layouts | roots], MapSet.new())
    |> Enum.flat_map(&[Map.fetch!(web, &1) | templates(&1)])
    |> Enum.uniq()
  end

  # The .heex files a module compiles in (embed_templates, a colocated
  # LiveView template): each is recorded as an external resource. Read from
  # the .beam file for the same reason as web_source/1.
  defp templates(module) do
    {:ok, {^module, [attributes: attributes]}} =
      :beam_lib.chunks(beam(module), [:attributes])

    for path <- Keyword.get_values(attributes, :external_resource),
        path = Path.expand(to_string(path)),
        String.ends_with?(path, ".heex"),
        do: path
  end

  defp walk(_web, [], seen), do: seen

  defp walk(web, [module | rest], seen) do
    if module in seen or module in @not_followed or not Map.has_key?(web, module) do
      walk(web, rest, seen)
    else
      walk(web, callees(module) ++ rest, MapSet.put(seen, module))
    end
  end

  # Read from the .beam file rather than module_info/1, which would load all
  # of the app's modules first and slows the test past its timeout under a
  # full parallel run.
  defp web_source(module) do
    {:ok, {^module, [compile_info: info]}} = :beam_lib.chunks(beam(module), [:compile_info])
    source = info |> Keyword.get(:source, []) |> to_string()
    if String.contains?(source, "/lib/tymeslot_web"), do: Path.expand(source)
  end

  defp beam(module) do
    :tymeslot |> :code.lib_dir() |> Path.join("ebin/#{module}.beam") |> String.to_charlist()
  end

  # Every module the compiled code calls or names: the import table covers
  # remote calls, the atom table and the literal table cover modules used as
  # values. Atoms that are not web-layer modules are dropped by walk/3.
  defp callees(module) do
    beam = beam(module)

    {:ok, {^module, [imports: imports, atoms: atoms]}} =
      :beam_lib.chunks(beam, [:imports, :atoms])

    Enum.uniq(
      Enum.map(imports, &elem(&1, 0)) ++ Enum.map(atoms, &elem(&1, 1)) ++ literal_atoms(beam)
    )
  end

  defp literal_atoms(beam) do
    case :beam_lib.chunks(beam, [~c"LitT"]) do
      {:ok, {_module, [{~c"LitT", <<size::32, table::binary>>}]}} ->
        table = if size == 0, do: table, else: :zlib.uncompress(table)
        <<_count::32, entries::binary>> = table
        literal_atoms(entries, [])

      {:error, :beam_lib, {:missing_chunk, _beam, _chunk}} ->
        []
    end
  end

  defp literal_atoms(<<>>, acc), do: acc

  defp literal_atoms(<<size::32, term::binary-size(size), rest::binary>>, acc),
    do: literal_atoms(rest, atoms_in(:erlang.binary_to_term(term), acc))

  defp atoms_in(term, acc) when is_atom(term), do: [term | acc]
  defp atoms_in([head | tail], acc), do: atoms_in(tail, atoms_in(head, acc))
  defp atoms_in(term, acc) when is_tuple(term), do: atoms_in(Tuple.to_list(term), acc)
  defp atoms_in(term, acc) when is_map(term), do: atoms_in(Map.to_list(term), acc)
  defp atoms_in(_term, acc), do: acc
end
