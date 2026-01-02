defmodule TymeslotWeb.Themes.Core.Loader do
  @moduledoc """
  Dynamic theme loading and validation system.

  This module provides runtime theme loading capabilities while
  maintaining compatibility with the static Registry.
  """

  alias TymeslotWeb.Themes.Core.Registry
  require Logger

  @type load_result :: {:ok, module()} | {:error, term()}

  @doc """
  Loads a theme module dynamically by its ID.

  This function ensures the module is loaded and validates
  it implements the required behavior.
  """
  @spec load_theme(String.t()) :: load_result()
  def load_theme(theme_id) do
    with {:ok, theme} <- Registry.get_theme_by_id(theme_id),
         {:ok, module} <- ensure_loaded(theme.module),
         :ok <- validate_theme_module(module) do
      {:ok, module}
    else
      {:error, :theme_not_found} = error ->
        Logger.error("Theme not found with ID: #{theme_id}")
        error

      {:error, reason} = error ->
        Logger.error("Failed to load theme #{theme_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Loads a theme module by its key.
  """
  @spec load_theme_by_key(atom()) :: load_result()
  def load_theme_by_key(theme_key) do
    with {:ok, theme} <- Registry.get_theme_by_key(theme_key) do
      load_theme(theme.id)
    end
  end

  @doc """
  Preloads all active themes to ensure they're available.

  This is useful during application startup.
  """
  @spec preload_all_themes() :: {:ok, [module()]} | {:error, term()}
  def preload_all_themes do
    results =
      Registry.active_themes()
      |> Map.values()
      |> Enum.map(fn theme ->
        case load_theme(theme.id) do
          {:ok, module} -> {:ok, {theme.id, module}}
          error -> {:error, {theme.id, error}}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      modules = Enum.map(results, fn {:ok, {_id, module}} -> module end)
      {:ok, modules}
    else
      {:error, errors}
    end
  end

  @doc """
  Validates that a theme module implements all required callbacks.
  """
  @spec validate_theme_module(module()) :: :ok | {:error, term()}
  def validate_theme_module(module) do
    required_functions = [
      {:states, 0},
      {:css_file, 0},
      {:components, 0},
      {:live_view_module, 0},
      {:theme_config, 0},
      {:validate_theme, 0},
      {:initial_state_for_action, 1},
      {:supports_feature?, 1}
    ]

    missing_functions =
      Enum.reject(required_functions, fn {func, arity} ->
        function_exported?(module, func, arity)
      end)

    if Enum.empty?(missing_functions) do
      :ok
    else
      {:error, {:missing_functions, missing_functions}}
    end
  end

  @doc """
  Gets the LiveView module for a theme, with dynamic loading.
  """
  @spec get_live_view_module(String.t()) :: module() | nil
  def get_live_view_module(theme_id) do
    case load_theme(theme_id) do
      {:ok, module} ->
        try do
          module.live_view_module()
        rescue
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Reloads a theme module in development.

  This is useful for hot-reloading during development.
  """
  @spec reload_theme(String.t()) :: load_result()
  def reload_theme(theme_id) do
    if Application.get_env(:tymeslot, :environment) == :dev do
      with {:ok, theme} <- Registry.get_theme_by_id(theme_id) do
        # Purge the module first
        :code.purge(theme.module)
        :code.delete(theme.module)

        # Reload it
        load_theme(theme_id)
      end
    else
      {:error, :not_in_dev_mode}
    end
  end

  @doc """
  Checks if a theme is currently loaded.
  """
  @spec theme_loaded?(String.t()) :: boolean()
  def theme_loaded?(theme_id) do
    case Registry.get_theme_by_id(theme_id) do
      {:ok, theme} ->
        case ensure_loaded(theme.module) do
          {:ok, _} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # Private functions

  defp ensure_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        {:ok, module}

      {:error, reason} ->
        {:error, {:module_not_loaded, reason}}
    end
  end
end
