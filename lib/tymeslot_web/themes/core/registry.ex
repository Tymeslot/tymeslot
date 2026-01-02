defmodule TymeslotWeb.Themes.Core.Registry do
  @moduledoc """
  Centralized registry for all available themes in the system.

  This module provides a single source of truth for theme definitions,
  eliminating magic strings and providing type-safe theme access.
  """

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

  # Define all themes with their metadata
  @themes %{
    quill: %{
      id: "1",
      key: :quill,
      name: "Quill",
      description: "Professional glassmorphism theme with elegant transparency effects",
      module: TymeslotWeb.Themes.Quill.Theme,
      css_file: "/assets/scheduling-theme-quill.css",
      preview_image: "/images/themes/quill-preview.png",
      features: %{
        supports_video_background: true,
        supports_image_background: true,
        supports_gradient_background: true,
        supports_custom_colors: true,
        flow_type: :multi_step,
        step_count: 4
      },
      status: :active
    },
    rhythm: %{
      id: "2",
      key: :rhythm,
      name: "Rhythm",
      description: "Modern sliding theme with immersive video backgrounds",
      module: TymeslotWeb.Themes.Rhythm.Theme,
      css_file: "/assets/scheduling-theme-rhythm.css",
      preview_image: "/images/themes/rhythm-preview.png",
      features: %{
        supports_video_background: true,
        supports_image_background: true,
        supports_gradient_background: true,
        supports_custom_colors: true,
        flow_type: :single_page,
        step_count: 2
      },
      status: :active
    }
  }

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
