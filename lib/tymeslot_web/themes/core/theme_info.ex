defmodule TymeslotWeb.Themes.Core.ThemeInfo do
  @moduledoc """
  Convenience accessors over the theme system for the web layer.

  Resolves full theme metadata, loads theme modules, and exposes per-theme
  runtime details (states, LiveView module, CSS file) by combining the registry
  definitions with the theme behaviour callbacks. This is a
  presentation-layer concern: domain code reads theme facts from
  `Tymeslot.Themes.Catalog` instead.
  """

  require Logger

  alias TymeslotWeb.Themes.Core.{Loader, Registry}

  @doc """
  Returns all available themes with their metadata.
  """
  @spec all_themes() :: list(map())
  def all_themes do
    Registry.all_themes()
    |> Enum.map(fn {_key, theme} ->
      config = theme.module.theme_config()
      {theme.id, Map.put(config, :id, theme.id)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Gets theme metadata by ID.
  """
  @spec get_theme(term()) :: map() | nil
  def get_theme(id) do
    case Registry.get_theme_by_id(to_string(id)) do
      {:ok, theme} ->
        config = theme.module.theme_config()
        Map.put(config, :id, theme.id)

      {:error, :theme_not_found} ->
        nil
    end
  end

  @doc """
  Gets the theme module implementation for a given ID.
  Uses dynamic loading to ensure the module is available.
  """
  @spec get_theme_module(term()) :: module() | nil
  def get_theme_module(id) do
    case Loader.load_theme(to_string(id)) do
      {:ok, module} -> module
      {:error, _reason} -> nil
    end
  end

  @doc """
  Gets theme name by ID.
  """
  @spec get_theme_name(term()) :: String.t()
  def get_theme_name(id) do
    case get_theme(id) do
      nil -> "Unknown"
      theme -> theme.name
    end
  end

  @doc """
  Gets theme description by ID.
  """
  @spec get_description(term()) :: String.t()
  def get_description(id) do
    case get_theme(id) do
      nil -> "A beautiful theme for your booking page."
      theme -> theme.description
    end
  end

  @doc """
  Validates if a theme ID is valid and theme is properly implemented.
  """
  @spec valid_theme_id?(term()) :: boolean()
  def valid_theme_id?(id) do
    theme_id = to_string(id)

    with true <- Registry.valid_theme_id?(theme_id),
         module when is_atom(module) <- get_theme_module(theme_id),
         :ok <- module.validate_theme() do
      true
    else
      false ->
        false

      nil ->
        false

      {:error, reason} ->
        Logger.warning("Theme validation failed", theme_id: id, reason: reason)
        false
    end
  end

  @doc """
  Returns theme options for form selects.
  """
  @spec theme_options() :: list({String.t(), String.t()})
  def theme_options do
    all_themes()
    |> Enum.map(fn {id, theme} -> {theme.name, id} end)
    |> Enum.sort_by(fn {_name, id} -> id end)
  end

  @doc """
  Gets the CSS file path for a theme.
  """
  @spec get_css_file(term()) :: String.t() | nil
  def get_css_file(id) do
    case Registry.get_css_file_by_id(to_string(id)) do
      {:ok, css_file} -> css_file
      {:error, :theme_not_found} -> nil
    end
  end

  @doc """
  Gets the LiveView module for a theme.
  Uses dynamic loading to ensure the module is available.
  """
  @spec get_live_view_module(term()) :: module() | nil
  def get_live_view_module(id) do
    Loader.get_live_view_module(to_string(id))
  end

  @doc """
  Checks if a theme supports a specific feature.
  """
  @spec supports_feature?(term(), atom()) :: boolean()
  def supports_feature?(id, feature) do
    case get_theme_module(id) do
      nil -> false
      module -> module.supports_feature?(feature)
    end
  end
end
