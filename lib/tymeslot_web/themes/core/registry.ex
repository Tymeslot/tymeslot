defmodule TymeslotWeb.Themes.Core.Registry do
  @moduledoc """
  Centralized registry for all available themes in the system.

  This module provides a single source of truth for theme *definitions* —
  theme facts (sourced from `Tymeslot.Themes.Catalog`) merged with the
  presentation bindings the web layer owns: the theme module, its CSS file, and
  its preview image. Domain code reads facts directly from the catalog; only the
  web layer needs these full definitions.
  """

  alias Tymeslot.Themes.Catalog

  @type theme_id :: String.t()
  @type theme_key :: atom()

  @type theme_definition :: %{
          id: theme_id(),
          key: theme_key(),
          name: String.t(),
          description: String.t(),
          module: module(),
          css_file: String.t(),
          preview_image: String.t() | nil,
          features: map(),
          status: :active | :beta | :deprecated
        }

  # Presentation bindings keyed by theme ID. The web layer owns these; the
  # theme facts they are merged with live in Tymeslot.Themes.Catalog.
  @bindings %{
    "1" => %{
      module: TymeslotWeb.Themes.Quill.Theme,
      css_file: "/assets/scheduling-theme-quill.css",
      preview_image: "/images/themes/quill-preview.png"
    },
    "2" => %{
      module: TymeslotWeb.Themes.Rhythm.Theme,
      css_file: "/assets/scheduling-theme-rhythm.css",
      preview_image: "/images/themes/rhythm-preview.png"
    }
  }

  # Build full definitions at compile time by merging catalog facts with bindings.
  @themes Catalog.all()
          |> Enum.map(fn {key, facts} ->
            {key, Map.merge(facts, Map.fetch!(@bindings, facts.id))}
          end)
          |> Map.new()

  # Create reverse lookup maps at compile time
  @id_to_key_map @themes
                 |> Enum.map(fn {key, theme} -> {theme.id, key} end)
                 |> Map.new()

  @id_to_theme_map @themes
                   |> Enum.map(fn {_key, theme} -> {theme.id, theme} end)
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
  Returns all active themes (excludes deprecated themes).
  """
  @spec active_themes() :: %{theme_key() => theme_definition()}
  def active_themes do
    @themes
    |> Enum.filter(fn {_key, theme} -> theme.status == :active end)
    |> Map.new()
  end

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
  Gets a theme by its ID, raises if not found.
  """
  @spec get_theme_by_id!(theme_id()) :: theme_definition()
  def get_theme_by_id!(id) when is_binary(id) do
    case get_theme_by_id(id) do
      {:ok, theme} -> theme
      {:error, :theme_not_found} -> raise "Theme with ID #{id} not found"
    end
  end

  @doc """
  Gets a theme by its key.

  ## Examples

      iex> Registry.get_theme_by_key(:quill)
      {:ok, %{id: "1", key: :quill, name: "Quill", ...}}
  """
  @spec get_theme_by_key(theme_key()) :: {:ok, theme_definition()} | {:error, :theme_not_found}
  def get_theme_by_key(key) when is_atom(key) do
    case Map.get(@themes, key) do
      nil -> {:error, :theme_not_found}
      theme -> {:ok, theme}
    end
  end

  @doc """
  Gets a theme by its key, raises if not found.
  """
  @spec get_theme_by_key!(theme_key()) :: theme_definition()
  def get_theme_by_key!(key) when is_atom(key) do
    case get_theme_by_key(key) do
      {:ok, theme} -> theme
      {:error, :theme_not_found} -> raise "Theme with key #{key} not found"
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
  Converts a theme key to its ID.

  ## Examples

      iex> Registry.key_to_id(:quill)
      {:ok, "1"}
  """
  @spec key_to_id(theme_key()) :: {:ok, theme_id()} | {:error, :invalid_theme_key}
  def key_to_id(key) when is_atom(key) do
    case Map.get(@themes, key) do
      nil -> {:error, :invalid_theme_key}
      %{id: id} -> {:ok, id}
    end
  end

  @doc """
  Returns a list of valid theme IDs.

  ## Examples

      iex> Registry.valid_theme_ids()
      ["1", "2"]
  """
  @spec valid_theme_ids() :: [theme_id()]
  def valid_theme_ids do
    @themes
    |> Map.values()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  @doc """
  Returns a list of valid theme keys.

  ## Examples

      iex> Registry.valid_theme_keys()
      [:quill, :rhythm]
  """
  @spec valid_theme_keys() :: [theme_key()]
  def valid_theme_keys do
    @themes
    |> Map.keys()
    |> Enum.sort()
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

  @doc """
  Checks if a theme key is valid.
  """
  @spec valid_theme_key?(theme_key()) :: boolean()
  def valid_theme_key?(key) when is_atom(key) do
    Map.has_key?(@themes, key)
  end

  @doc """
  Gets the default theme definition.

  Returns the Quill theme as the default.
  """
  @spec default_theme() :: theme_definition()
  def default_theme do
    @themes.quill
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
  Returns themes that support a specific feature.

  ## Examples

      iex> Registry.themes_with_feature(:supports_video_background)
      [%{key: :quill, ...}, %{key: :rhythm, ...}]
  """
  @spec themes_with_feature(atom()) :: [theme_definition()]
  def themes_with_feature(feature) when is_atom(feature) do
    @themes
    |> Map.values()
    |> Enum.filter(fn theme ->
      Map.get(theme.features, feature, false) == true
    end)
  end

  @doc """
  Gets theme module by ID.

  ## Examples

      iex> Registry.get_module_by_id("1")
      {:ok, TymeslotWeb.Themes.Quill.Theme}
  """
  @spec get_module_by_id(theme_id()) :: {:ok, module()} | {:error, :theme_not_found}
  def get_module_by_id(id) when is_binary(id) do
    case get_theme_by_id(id) do
      {:ok, theme} -> {:ok, theme.module}
      error -> error
    end
  end

  @doc """
  Gets theme CSS file by ID.
  """
  @spec get_css_file_by_id(theme_id()) :: {:ok, String.t()} | {:error, :theme_not_found}
  def get_css_file_by_id(id) when is_binary(id) do
    case get_theme_by_id(id) do
      {:ok, theme} -> {:ok, theme.css_file}
      error -> error
    end
  end
end
