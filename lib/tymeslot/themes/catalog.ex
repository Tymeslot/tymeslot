defmodule Tymeslot.Themes.Catalog do
  @moduledoc """
  Domain source of truth for theme *facts*: which themes exist and how each is
  customised.

  Holds each theme's id, key, name, customisation spec, `heading_style`, and
  status. This is pure data with no web or presentation dependency: profiles and
  theme customizations validate and drive behaviour off these facts without ever
  reaching up into the web layer.

  The web layer (`TymeslotWeb.Themes.Core.Registry`) binds each theme id to its
  theme module, but the facts themselves live here so the dependency only ever
  flows web → domain.

  `heading_style` says whether the booking page's default heading names the
  organiser (`:named`) or greets generically (`:generic`).

  Themes may also be registered through `config :tymeslot, :extra_themes`, a
  list of fact maps each with the theme's web `:module` besides, which this
  module drops and `TymeslotWeb.Themes.Core.Registry` binds. Only
  `config/test.exs` sets it, to register the test-only themes under
  `test/support/`; every other build holds exactly the themes below.
  """

  @type theme_id :: String.t()
  @type theme_key :: atom()
  @type status :: :active | :beta | :deprecated
  @type heading_style :: :named | :generic
  @type theme_facts :: %{
          id: theme_id(),
          key: theme_key(),
          name: String.t(),
          customization_spec: module(),
          heading_style: heading_style(),
          status: status()
        }

  @default_key :quill

  # Read at compile time; empty in every build but the test one (see the
  # moduledoc). The entries are plain atoms from config, not aliases, so they
  # add no compile-time dependency either.
  @extra_themes Application.compile_env(:tymeslot, :extra_themes, [])

  # The facts live in function bodies rather than module attributes, so the
  # spec modules they name stay runtime references: an alias in a module
  # attribute would make the Catalog, and everything that reads it at compile
  # time, depend on the specs at compile time.
  defp themes, do: merge_extra_themes!(shipped_themes(), @extra_themes)

  defp shipped_themes do
    %{
      quill: %{
        id: "1",
        key: :quill,
        name: "Quill",
        heading_style: :generic,
        customization_spec: Tymeslot.ThemeCustomizations.QuillSpec,
        status: :active
      },
      rhythm: %{
        id: "2",
        key: :rhythm,
        name: "Rhythm",
        heading_style: :named,
        customization_spec: Tymeslot.ThemeCustomizations.RhythmSpec,
        status: :active
      }
    }
  end

  # Adds the extra themes' facts to the shipped ones, refusing an entry that
  # reuses a shipped id or key: the merge would otherwise let it silently
  # replace the shipped theme. `TymeslotWeb.Themes.Core.Registry` reads
  # `all/0` while it compiles, so a clashing config fails the build there.
  # Public (and undocumented) so a test can hand it a clashing entry.
  @doc false
  @spec merge_extra_themes!(%{theme_key() => map()}, [map()]) :: %{theme_key() => map()}
  def merge_extra_themes!(shipped, extras) do
    for %{id: id, key: key} <- extras, {shipped_key, %{id: shipped_id}} <- shipped do
      if id == shipped_id or key == shipped_key do
        raise ArgumentError,
              "config :tymeslot, :extra_themes entry #{inspect(key)} (id #{inspect(id)}) " <>
                "clashes with the shipped theme #{inspect(shipped_key)} (id #{inspect(shipped_id)})"
      end
    end

    Map.merge(shipped, Map.new(extras, &{&1.key, Map.delete(&1, :module)}))
  end

  defp id_to_key_map, do: Map.new(themes(), fn {key, theme} -> {theme.id, key} end)

  defp id_to_facts_map, do: Map.new(themes(), fn {_key, theme} -> {theme.id, theme} end)

  @doc """
  Returns all theme facts keyed by theme key.
  """
  @spec all() :: %{theme_key() => theme_facts()}
  def all, do: themes()

  @doc """
  Returns the facts for all active themes (excludes beta and deprecated).
  """
  @spec active() :: %{theme_key() => theme_facts()}
  def active do
    themes()
    |> Enum.filter(fn {_key, theme} -> theme.status == :active end)
    |> Map.new()
  end

  @doc """
  Gets theme facts by ID.
  """
  @spec get_by_id(theme_id()) :: {:ok, theme_facts()} | {:error, :theme_not_found}
  def get_by_id(id) when is_binary(id) do
    case Map.get(id_to_facts_map(), id) do
      nil -> {:error, :theme_not_found}
      facts -> {:ok, facts}
    end
  end

  @doc """
  Converts a theme ID to its key.
  """
  @spec id_to_key(theme_id()) :: {:ok, theme_key()} | {:error, :invalid_theme_id}
  def id_to_key(id) when is_binary(id) do
    case Map.get(id_to_key_map(), id) do
      nil -> {:error, :invalid_theme_id}
      key -> {:ok, key}
    end
  end

  @doc """
  Converts a theme key to its ID.
  """
  @spec key_to_id(theme_key()) :: {:ok, theme_id()} | {:error, :invalid_theme_key}
  def key_to_id(key) when is_atom(key) do
    case Map.get(themes(), key) do
      nil -> {:error, :invalid_theme_key}
      %{id: id} -> {:ok, id}
    end
  end

  @doc """
  Returns the sorted list of valid theme IDs.
  """
  @spec valid_ids() :: [theme_id()]
  def valid_ids do
    themes()
    |> Map.values()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  @doc """
  Returns the sorted list of valid theme keys.
  """
  @spec valid_keys() :: [theme_key()]
  def valid_keys do
    themes()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Checks whether a theme ID is registered.
  """
  @spec valid_id?(theme_id()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Map.has_key?(id_to_facts_map(), id)

  @doc """
  Returns the default theme's facts (Quill).
  """
  @spec default() :: theme_facts()
  def default, do: Map.fetch!(themes(), @default_key)

  @doc """
  Returns the default theme ID.
  """
  @spec default_id() :: theme_id()
  def default_id, do: default().id

  @doc """
  Returns the default theme key.
  """
  @spec default_key() :: theme_key()
  def default_key, do: default().key

  @doc """
  Returns the customisation spec module for a theme ID.
  """
  @spec customization_spec(theme_id()) :: {:ok, module()} | {:error, :theme_not_found}
  def customization_spec(id) when is_binary(id) do
    with {:ok, %{customization_spec: spec}} <- get_by_id(id), do: {:ok, spec}
  end
end
