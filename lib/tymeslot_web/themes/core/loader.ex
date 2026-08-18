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
        Logger.error("Theme not found", theme_id: theme_id)
        error

      {:error, reason} = error ->
        Logger.error("Failed to load theme", theme_id: theme_id, reason: inspect(reason))
        error
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
      {:supports_feature?, 1},
      {:render_poll_action, 1}
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
          error ->
            Logger.warning("Theme module failed to report its LiveView module",
              theme_id: theme_id,
              theme_module: inspect(module),
              error: inspect(error)
            )

            nil
        end

      {:error, _reason} ->
        nil
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
