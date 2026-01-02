defmodule TymeslotWeb.Themes.Core.Validator do
  @moduledoc """
  Validation utilities for theme system integrity.
  """

  alias Tymeslot.Themes.Theme

  require Logger

  @doc """
  Validates that all registered themes are properly implemented.
  """
  @spec validate_all_themes() :: :ok | {:error, list()}
  def validate_all_themes do
    case Theme.validate_all_themes() do
      :ok ->
        Logger.info("✅ All themes validated successfully")
        :ok

      {:error, failed_themes} ->
        Logger.error("❌ Theme validation failures:")

        Enum.each(failed_themes, fn {theme_id, {:error, reason}} ->
          Logger.error("  - Theme #{theme_id}: #{reason}")
        end)

        {:error, failed_themes}
    end
  end

  @doc """
  Validates theme independence by checking that themes can be loaded independently.
  """
  @spec validate_theme_independence() :: :ok | {:error, list()}
  def validate_theme_independence do
    all_themes = Theme.all_themes()

    Logger.info("🔍 Testing theme independence for #{Enum.count(all_themes)} themes...")

    results =
      Enum.map(all_themes, fn {theme_id, _theme_info} ->
        {theme_id, test_theme_independence(theme_id)}
      end)

    failed_tests = Enum.filter(results, fn {_theme_id, result} -> result != :ok end)

    if Enum.empty?(failed_tests) do
      Logger.info("✅ All themes are properly independent")
      :ok
    else
      Logger.error("❌ Theme independence failures:")

      Enum.each(failed_tests, fn {theme_id, {:error, reason}} ->
        Logger.error("  - Theme #{theme_id}: #{reason}")
      end)

      {:error, failed_tests}
    end
  end

  @doc """
  Validates that theme components can be loaded independently.
  """
  @spec validate_theme_components() :: :ok | {:error, list()}
  def validate_theme_components do
    all_themes = Theme.all_themes()

    Logger.info("🧩 Testing theme components for #{Enum.count(all_themes)} themes...")

    results =
      Enum.flat_map(all_themes, fn {theme_id, _theme_info} ->
        components = Theme.get_components(theme_id)

        Enum.map(components, fn {component_name, component_module} ->
          {{theme_id, component_name}, test_component_loading(component_module)}
        end)
      end)

    failed_components = Enum.filter(results, fn {_component_key, result} -> result != :ok end)

    if Enum.empty?(failed_components) do
      Logger.info("✅ All theme components load successfully")
      :ok
    else
      Logger.error("❌ Theme component loading failures:")

      Enum.each(failed_components, fn {{theme_id, component_name}, {:error, reason}} ->
        Logger.error("  - Theme #{theme_id}, Component #{component_name}: #{reason}")
      end)

      {:error, failed_components}
    end
  end

  @doc """
  Runs a comprehensive theme system validation.
  """
  @spec run_full_validation() :: :ok | {:error, list()}
  def run_full_validation do
    Logger.info("🚀 Running comprehensive theme system validation...")

    results = [
      {"Theme Registration", validate_all_themes()},
      {"Theme Independence", validate_theme_independence()},
      {"Component Loading", validate_theme_components()}
    ]

    failed_validations = Enum.filter(results, fn {_name, result} -> result != :ok end)

    if Enum.empty?(failed_validations) do
      Logger.info("🎉 All theme system validations passed!")
      :ok
    else
      Logger.error("💥 Theme system validation failures:")

      Enum.each(failed_validations, fn {validation_name, _error} ->
        Logger.error("  - #{validation_name} failed")
      end)

      {:error, failed_validations}
    end
  end

  # Private functions

  defp test_theme_independence(theme_id) do
    # Test that theme module can be loaded
    theme_module = Theme.get_theme_module(theme_id)

    if theme_module == nil do
      {:error, "Theme module not found"}
    else
      # Test that all behavior functions are implemented
      case Code.ensure_loaded(theme_module) do
        {:module, ^theme_module} ->
          test_behavior_implementation(theme_module)

        {:error, reason} ->
          {:error, "Failed to load theme module: #{reason}"}
      end
    end
  rescue
    e -> {:error, "Exception during theme independence test: #{inspect(e)}"}
  end

  defp test_behavior_implementation(theme_module) do
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
      Enum.filter(required_functions, fn {func, arity} ->
        not function_exported?(theme_module, func, arity)
      end)

    if Enum.empty?(missing_functions) do
      :ok
    else
      {:error, "Missing behavior functions: #{inspect(missing_functions)}"}
    end
  end

  defp test_component_loading(component_module) do
    case Code.ensure_loaded(component_module) do
      {:module, ^component_module} ->
        # Test that it's a valid LiveComponent
        if function_exported?(component_module, :update, 2) do
          :ok
        else
          {:error, "Component does not implement LiveComponent behavior"}
        end

      {:error, reason} ->
        {:error, "Failed to load component module: #{reason}"}
    end
  rescue
    e -> {:error, "Exception during component loading test: #{inspect(e)}"}
  end
end
