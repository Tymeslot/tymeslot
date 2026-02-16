defmodule TymeslotWeb.Plugs.ThemeProtectionPlug do
  @moduledoc """
  A generic plug that executes a list of configured protection plugs.
  This allows distribution layers (like SaaS) to inject additional 
  protections into the core theme/scheduling pipeline without 
  the core application being aware of them.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Get any extra protection plugs from configuration
    plugs = Application.get_env(:tymeslot, :extra_theme_protection_plugs, [])

    Enum.reduce_while(plugs, conn, fn plug_info, acc_conn ->
      {plug_mod, plug_opts} = normalize_plug(plug_info)

      case plug_mod.call(acc_conn, plug_mod.init(plug_opts)) do
        %Plug.Conn{halted: true} = halted_conn -> {:halt, halted_conn}
        updated_conn -> {:cont, updated_conn}
      end
    end)
  end

  defp normalize_plug(plug_mod) when is_atom(plug_mod), do: {plug_mod, []}
  defp normalize_plug({plug_mod, opts}), do: {plug_mod, opts}
end
