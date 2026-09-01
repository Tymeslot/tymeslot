defmodule TymeslotWeb.Themes.Core.Behaviour do
  @moduledoc """
  Behaviour for theme implementations to ensure complete independence.

  Each theme can define its own flow, components, and UI patterns while
  maintaining a consistent interface for the main scheduling system.
  """

  @doc """
  Returns the state machine definition for this theme.
  Each theme can have its own flow (2-step, 4-step, etc.)

  Declarative only: the *runtime* flow comes from the shared
  `Shared.StateMachineHelpers.states_for/1`, not from this callback. No
  production code calls `states/0` today — `Loader`/`Validator` still enforce
  it via `function_exported?/3`, and `ThemeCommonTestCases` exercises it
  directly, so it stays part of the contract as a documented, tested
  declaration of each theme's step shape.
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

  No production code calls this today — `Loader`/`Validator` still enforce
  it via `function_exported?/3`, and `ThemeCommonTestCases` exercises it
  directly, so it stays part of the contract as documented, tested behaviour.
  """
  @callback initial_state_for_action(atom()) :: atom()

  @doc """
  Returns whether this theme supports a specific feature.
  Allows themes to opt-in/out of certain functionality.
  """
  @callback supports_feature?(atom()) :: boolean()

  @doc """
  Renders a meeting management action (cancel, reschedule, etc.)
  """
  @callback render_meeting_action(assigns :: map(), action :: atom()) ::
              Phoenix.LiveView.Rendered.t()

  @doc """
  Renders the public poll voting page for this theme.
  """
  @callback render_poll_action(assigns :: map()) :: Phoenix.LiveView.Rendered.t()
end
