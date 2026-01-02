defmodule TymeslotWeb.Themes.Core.Behaviour do
  @moduledoc """
  Behaviour for theme implementations to ensure complete independence.

  Each theme can define its own flow, components, and UI patterns while
  maintaining a consistent interface for the main scheduling system.
  """

  @doc """
  Returns the state machine definition for this theme.
  Each theme can have its own flow (2-step, 4-step, etc.)
  """
  @callback states() :: map()

  @doc """
  Returns the CSS file path for this theme.
  """
  @callback css_file() :: String.t()

  @doc """
  Returns the available components for this theme.
  Components are mapped by their role in the scheduling flow.
  """
  @callback components() :: map()

  @doc """
  Returns the main LiveView module for this theme.
  Each theme can have its own LiveView implementation.
  """
  @callback live_view_module() :: module()

  @doc """
  Returns theme-specific configuration or options.
  """
  @callback theme_config() :: map()

  @doc """
  Validates that all required components exist for this theme.
  """
  @callback validate_theme() :: :ok | {:error, String.t()}

  @doc """
  Returns the initial state for a given live_action.
  Allows themes to customize how routes map to states.
  """
  @callback initial_state_for_action(atom()) :: atom()

  @doc """
  Returns whether this theme supports a specific feature.
  Allows themes to opt-in/out of certain functionality.
  """
  @callback supports_feature?(atom()) :: boolean()
end
