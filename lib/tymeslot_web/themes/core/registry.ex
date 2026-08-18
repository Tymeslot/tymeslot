defmodule TymeslotWeb.Themes.Core.Registry do
  @moduledoc """
  Centralized registry for all available themes in the system.

  This module provides a single source of truth for theme *definitions* —
  theme facts (sourced from `Tymeslot.Themes.Catalog`) merged with the
  presentation bindings the web layer owns: the theme module and its CSS file.
  The preview image lives in each theme's `theme_config/0` callback. Domain code
  reads facts directly from the catalog; only the web layer needs these full
  definitions.
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
          features: map(),
          status: :active | :beta | :deprecated
        }

  # Presentation bindings keyed by theme ID. The web layer owns these; the
  # theme facts they are merged with live in Tymeslot.Themes.Catalog.
  @bindings %{
    "1" => %{
      module: TymeslotWeb.Themes.Quill.Theme,
      css_file: "/assets/scheduling-theme-quill.css"
    },
    "2" => %{
      module: TymeslotWeb.Themes.Rhythm.Theme,
      css_file: "/assets/scheduling-theme-rhythm.css"
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
