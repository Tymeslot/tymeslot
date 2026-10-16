defmodule TymeslotWeb.Themes.Core.Registry.Definitions do
  @moduledoc """
  Joins the catalogue's theme facts to each theme's module, for
  `TymeslotWeb.Themes.Core.Registry`, which calls `build!/2` while it
  compiles.

  A shipped theme's module follows from its catalogue key by convention:
  `:quill` is `TymeslotWeb.Themes.Quill.Theme` (see `conventional_module/1`).
  The module is built from strings, so nothing here, and nothing in the
  Registry, references a theme module at compile time. The Registry has no
  compile-time dependency on the themes, so editing a theme recompiles
  nothing else, and adding a theme needs no registry line. Themes registered
  through `:extra_themes` (the test build's test-only themes) keep the module
  their entry names.

  Plain data in and out: this module names no other, so the Registry's
  compile-time dependency on it adds nothing to the compile graph.
  """

  @doc """
  Every theme's facts with its module under `:module`, keyed as the facts
  are. A theme's module is its entry in `extra_bindings` (keyed by theme id)
  or else its `conventional_module/1`. Raises `ArgumentError` when
  `extra_bindings` names an id `facts` does not hold.
  """
  @spec build!(%{atom() => map()}, %{String.t() => module()}) :: %{atom() => map()}
  def build!(facts, extra_bindings) do
    ids = Enum.map(facts, fn {_key, theme} -> theme.id end)

    case Enum.sort(Map.keys(extra_bindings) -- ids) do
      [] ->
        Map.new(facts, fn {key, theme} ->
          module = Map.get(extra_bindings, theme.id, conventional_module(key))
          {key, Map.put(theme, :module, module)}
        end)

      unknown ->
        raise ArgumentError,
              "theme registration: :extra_themes entries with no " <>
                "Tymeslot.Themes.Catalog theme: #{inspect(unknown)} " <>
                "(add the theme's facts to the Catalog, or remove the entry)"
    end
  end

  @doc """
  The module a shipped theme is expected to define, from its catalogue key:
  `:quill` is `TymeslotWeb.Themes.Quill.Theme`.
  """
  @spec conventional_module(atom()) :: module()
  def conventional_module(key) do
    # Keys come from the compiled-in Catalog, never from user input, and the module
    # may not be loaded yet (that is the point), so safe_concat/1 does not apply.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    Module.concat(["TymeslotWeb", "Themes", Macro.camelize(Atom.to_string(key)), "Theme"])
  end
end
