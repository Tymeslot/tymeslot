defmodule TymeslotWeb.Plugs.AdditionalDashboardPlugs do
  @moduledoc """
  Runs the plugs configured under `:dashboard_additional_plugs`.

  The controller-side counterpart to the `:dashboard_additional_hooks`
  `on_mount` chain. A deployment layered on top of Core can already gate
  dashboard LiveViews through that chain, but an `on_mount` hook runs only
  when a LiveView mounts: a plain controller action in the same authenticated
  scope is reached by an ordinary HTTP request and never sees it. Without a
  controller-side equivalent, any such gate is enforced for the UI and not for
  the endpoint behind it.

  Core configures nothing here, so a standalone deployment runs an empty list
  and the plug is inert.
  """

  require Logger

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    Enum.reduce_while(configured_plugs(), conn, fn plug, conn ->
      case run(plug, conn) do
        %Plug.Conn{halted: true} = halted -> {:halt, halted}
        continued -> {:cont, continued}
      end
    end)
  end

  defp run({module, opts}, conn), do: module.call(conn, module.init(opts))
  defp run(module, conn) when is_atom(module), do: module.call(conn, module.init([]))

  # These plugs are deployment gates, so a configuration they cannot be run
  # from raises rather than being skipped: a typo must not quietly switch a
  # gate off. Every entry is checked before any plug runs.
  @spec configured_plugs() :: list()
  defp configured_plugs do
    :tymeslot
    |> Application.get_env(:dashboard_additional_plugs, [])
    |> normalise()
    |> Enum.map(&validate!/1)
  end

  defp normalise(plugs) when is_list(plugs), do: plugs

  defp normalise(plug) when is_tuple(plug) or is_atom(plug) do
    Logger.warning(
      "Expected :dashboard_additional_plugs to be a list, received a single plug. Wrapping."
    )

    [plug]
  end

  defp normalise(other) do
    raise ArgumentError,
          "expected :dashboard_additional_plugs to be a list of plugs, got: #{inspect(other)}"
  end

  defp validate!({module, _opts} = plug) when is_atom(module), do: plug
  defp validate!(module) when is_atom(module), do: module

  defp validate!(other) do
    raise ArgumentError,
          "unrecognised :dashboard_additional_plugs entry #{inspect(other)}; " <>
            "expected a module or a {module, opts} tuple"
  end
end
