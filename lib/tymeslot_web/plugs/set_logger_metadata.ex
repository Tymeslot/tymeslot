defmodule TymeslotWeb.Plugs.SetLoggerMetadata do
  @moduledoc false

  @behaviour Plug

  alias Tymeslot.Infrastructure.ErrorTracking

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    # Always set, `nil` included, so a reused Cowboy/Bandit worker cannot
    # inherit the previous request's user_id.
    user_id =
      case conn.assigns[:current_user] do
        %{id: id} -> id
        _no_user -> nil
      end

    ErrorTracking.put_context(user_id: user_id)
    conn
  end
end
