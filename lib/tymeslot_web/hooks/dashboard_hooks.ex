defmodule TymeslotWeb.Hooks.DashboardHooks do
  @moduledoc """
  The `on_mount` chains of the signed-in app: `:dashboard` and `:onboarding`.

  Both end in the deployment's `:dashboard_additional_hooks`, which are read
  when a LiveView mounts rather than when the router compiles, so a chain is a
  single hook that runs the others in turn.
  """

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Hooks.AnnouncementsHook
  alias TymeslotWeb.Hooks.AppLocaleHook
  alias TymeslotWeb.Hooks.AuthLiveSessionHook
  alias TymeslotWeb.Hooks.ClientInfoHook
  alias TymeslotWeb.Hooks.DashboardInitHook
  alias TymeslotWeb.Hooks.FeatureAssignsHook
  alias TymeslotWeb.Hooks.RouteBundleHook

  require Logger

  @dashboard_hooks [
    {AuthLiveSessionHook, :ensure_authenticated},
    AppLocaleHook,
    ClientInfoHook,
    DashboardInitHook,
    {FeatureAssignsHook, :set_feature_assigns},
    RouteBundleHook
  ]

  @onboarding_hooks [
    {AuthLiveSessionHook, :ensure_authenticated},
    AppLocaleHook,
    ClientInfoHook
  ]

  @doc false
  @spec on_mount(:dashboard | :onboarding, map(), map(), Socket.t()) ::
          {:cont, Socket.t()} | {:halt, Socket.t()}
  def on_mount(:dashboard, params, session, socket) do
    hooks =
      @dashboard_hooks ++
        dashboard_additional_hooks() ++
        [{AnnouncementsHook, :load_unseen_announcements}]

    run_hooks(hooks, params, session, socket)
  end

  # Onboarding sits outside the dashboard proper (DashboardInitHook would
  # redirect an unfinished user straight back here), but the deployment's
  # additional gates apply to it all the same.
  def on_mount(:onboarding, params, session, socket) do
    run_hooks(@onboarding_hooks ++ dashboard_additional_hooks(), params, session, socket)
  end

  @doc """
  The on_mount hooks configured under `:dashboard_additional_hooks`.

  These are deployment gates (a legal-acceptance check, for instance), so a
  configuration they cannot be run from raises rather than being skipped: a
  typo must not quietly switch a gate off.
  """
  @spec dashboard_additional_hooks() :: list()
  def dashboard_additional_hooks do
    :tymeslot
    |> Application.get_env(:dashboard_additional_hooks, [])
    |> normalise_additional_hooks()
    |> Enum.map(&validate_additional_hook!/1)
  end

  @doc """
  Boot-time check of `:dashboard_additional_hooks`: on top of the shape
  check every mount repeats, each hook module must be loadable and export
  `on_mount/4`, so a misspelt module name stops the application starting
  instead of surfacing at the first dashboard mount.
  """
  @spec validate_additional_hooks!() :: :ok
  def validate_additional_hooks! do
    Enum.each(dashboard_additional_hooks(), fn hook ->
      module = hook_module(hook)

      unless Code.ensure_loaded?(module) and function_exported?(module, :on_mount, 4) do
        raise ArgumentError,
              ":dashboard_additional_hooks entry #{inspect(hook)} names " <>
                "#{inspect(module)}, which does not define on_mount/4"
      end
    end)
  end

  defp hook_module({module, _hook_name}), do: module
  defp hook_module(module), do: module

  defp normalise_additional_hooks(hooks) when is_list(hooks), do: hooks

  defp normalise_additional_hooks(hook) when is_tuple(hook) or is_atom(hook) do
    Logger.warning(
      "Expected :dashboard_additional_hooks to be a list, received a single hook. Wrapping."
    )

    [hook]
  end

  defp normalise_additional_hooks(other) do
    raise ArgumentError,
          "expected :dashboard_additional_hooks to be a list of hooks, got: #{inspect(other)}"
  end

  defp validate_additional_hook!({module, hook_name} = hook)
       when is_atom(module) and is_atom(hook_name),
       do: hook

  defp validate_additional_hook!(module) when is_atom(module), do: module

  defp validate_additional_hook!(other) do
    raise ArgumentError,
          "unrecognised :dashboard_additional_hooks entry #{inspect(other)}; " <>
            "expected a module or a {module, hook_name} tuple"
  end

  defp run_hooks(hooks, params, session, socket) do
    Enum.reduce_while(hooks, {:cont, socket}, fn hook, {:cont, socket} ->
      case run_hook(hook, params, session, socket) do
        {:cont, socket} -> {:cont, {:cont, socket}}
        {:halt, socket} -> {:halt, {:halt, socket}}
      end
    end)
  end

  defp run_hook({module, hook_name}, params, session, socket),
    do: module.on_mount(hook_name, params, session, socket)

  defp run_hook(module, params, session, socket),
    do: module.on_mount(:default, params, session, socket)
end
