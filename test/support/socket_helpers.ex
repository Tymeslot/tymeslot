defmodule TymeslotWeb.Test.SocketHelpers do
  @moduledoc """
  A bare `Phoenix.LiveView.Socket` for calling hooks and event handlers
  directly, without mounting a LiveView.
  """

  alias Phoenix.LiveView.Socket

  @doc """
  A socket on `TymeslotWeb.Endpoint` carrying `assigns` over an empty
  `:flash` and change tracking.

  Options:

    * `:connected` - `true` gives the socket a transport pid (the test
      process), so `Phoenix.LiveView.connected?/1` holds. Defaults to `false`.
    * `:connect_info` - the map `get_connect_info/2` reads. Defaults to `%{}`.
    * `:uri` - shorthand for `connect_info: %{uri: URI.parse(uri)}`.
  """
  @spec build_socket(map(), keyword()) :: Socket.t()
  def build_socket(assigns \\ %{}, opts \\ []) do
    connect_info =
      case Keyword.fetch(opts, :uri) do
        {:ok, uri} -> %{uri: URI.parse(uri)}
        :error -> Keyword.get(opts, :connect_info, %{})
      end

    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, Map.new(assigns)),
      endpoint: TymeslotWeb.Endpoint,
      transport_pid: if(Keyword.get(opts, :connected, false), do: self()),
      private: Map.put(%Socket{}.private, :connect_info, connect_info)
    }
  end
end
