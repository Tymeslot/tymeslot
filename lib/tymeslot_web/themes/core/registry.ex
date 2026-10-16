defmodule TymeslotWeb.Themes.Core.Registry do
  @moduledoc """
  Single source of truth for theme *definitions* in the web layer: the facts
  from `Tymeslot.Themes.Catalog` joined to each theme's module. The stylesheet
  path (`/assets/scheduling-theme-<key>.css`) and html class (`<key>-theme`)
  derive from the key; the picker's preview image and description come from
  the module's `metadata/0`. Domain code reads facts from the catalog
  directly. A theme's module is derived from its key by convention
  (`:quill` is `TymeslotWeb.Themes.Quill.Theme`), so the registry never names a
  theme module and has no compile-time dependency on them.
  """

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.Registry.Definitions

  @type theme_id :: String.t()
  @type theme_key :: atom()

  @type theme_definition :: %{
          required(:id) => theme_id(),
          required(:key) => theme_key(),
          required(:name) => String.t(),
          required(:module) => module(),
          required(:customization_spec) => module(),
          required(:status) => Catalog.status(),
          optional(atom()) => term()
        }

  # Each shipped theme's module follows from its catalogue key
  # (`TymeslotWeb.Themes.<Key>.Theme`, see `Definitions.conventional_module/1`),
  # built from strings so this module does not depend on the theme modules at
  # compile time. Everything else the web layer needs is derived: the stylesheet
  # path and html class from the key, and the picker's preview image and
  # description from the module's `metadata/0`. Themes registered through
  # `:extra_themes` (the test build's test-only themes, see the Catalog's
  # moduledoc) bring their module in their entry.
  @extra_bindings :tymeslot
                  |> Application.compile_env(:extra_themes, [])
                  |> Map.new(&{&1.id, &1.module})

  # Full definitions, built while this module compiles: the Catalog's facts
  # joined to each theme's module. An extra theme entry with no facts fails the
  # build here, naming the id.
  @themes Definitions.build!(Catalog.all(), @extra_bindings)

  # Create reverse lookup maps at compile time
  @id_to_key_map @themes
                 |> Enum.map(fn {key, theme} -> {theme.id, key} end)
                 |> Map.new()

  @id_to_theme_map @themes
                   |> Enum.map(fn {_key, theme} -> {theme.id, theme} end)
                   |> Map.new()

  @slug_to_theme_map @themes
                     |> Enum.map(fn {key, theme} -> {Atom.to_string(key), theme} end)
                     |> Map.new()

  @doc """
  Returns all theme definitions.

  ## Examples

      iex> Registry.all_themes()
      %{
        quill: %{id: "1", name: "Quill", ...},
        rhythm: %{id: "2", name: "Rhythm", ...}
      }
  """
  @spec all_themes() :: %{theme_key() => theme_definition()}
  def all_themes, do: @themes

  @doc """
  Gets a theme by its ID.

  ## Examples

      iex> Registry.get_theme_by_id("1")
      {:ok, %{id: "1", key: :quill, name: "Quill", ...}}
      
      iex> Registry.get_theme_by_id("999")
      {:error, :theme_not_found}
  """
  @spec get_theme_by_id(theme_id()) :: {:ok, theme_definition()} | {:error, :theme_not_found}
  def get_theme_by_id(id) when is_binary(id) do
    case Map.get(@id_to_theme_map, id) do
      nil -> {:error, :theme_not_found}
      theme -> {:ok, theme}
    end
  end

  @doc """
  Gets a theme by its URL slug: the key as a string (`"quill"`).

  The payment return URLs carry the slug. Matching the string against
  precomputed keys never creates an atom from user input.
  """
  @spec get_theme_by_slug(String.t()) :: {:ok, theme_definition()} | {:error, :theme_not_found}
  def get_theme_by_slug(slug) when is_binary(slug) do
    case Map.get(@slug_to_theme_map, slug) do
      nil -> {:error, :theme_not_found}
      theme -> {:ok, theme}
    end
  end

  @doc """
  Converts a theme ID to its key.

  ## Examples

      iex> Registry.id_to_key("1")
      {:ok, :quill}
      
      iex> Registry.id_to_key("999")
      {:error, :invalid_theme_id}
  """
  @spec id_to_key(theme_id()) :: {:ok, theme_key()} | {:error, :invalid_theme_id}
  def id_to_key(id) when is_binary(id) do
    case Map.get(@id_to_key_map, id) do
      nil -> {:error, :invalid_theme_id}
      key -> {:ok, key}
    end
  end

  @doc """
  Checks if a theme ID is valid.

  ## Examples

      iex> Registry.valid_theme_id?("1")
      true
      
      iex> Registry.valid_theme_id?("999")
      false
  """
  @spec valid_theme_id?(theme_id()) :: boolean()
  def valid_theme_id?(id) when is_binary(id) do
    Map.has_key?(@id_to_theme_map, id)
  end

  # The default theme's definition. Which theme is the default is a catalog
  # fact, read at runtime so the choice lives in one place.
  @spec default_theme() :: theme_definition()
  defp default_theme do
    Map.fetch!(@themes, Catalog.default_key())
  end

  @doc """
  Gets the default theme ID.
  """
  @spec default_theme_id() :: theme_id()
  def default_theme_id do
    default_theme().id
  end

  @doc """
  Gets the default theme key.
  """
  @spec default_theme_key() :: theme_key()
  def default_theme_key do
    default_theme().key
  end

  @doc """
  The theme a URL asks for with `?theme=` (or the older `?theme_id=`), or
  `nil` when it names no registered theme.

  An unknown id counts as no request at all, so callers fall through to the
  organiser's theme and then the default, and the layout and the page always
  agree on which theme is showing.
  """
  @spec requested_theme_id(map()) :: theme_id() | nil
  def requested_theme_id(params) when is_map(params) do
    Enum.find_value(["theme", "theme_id"], fn key ->
      case params[key] do
        id when is_binary(id) -> if valid_theme_id?(id), do: id
        _absent -> nil
      end
    end)
  end
end
