defmodule TymeslotWeb.Plugs.SetLoggerMetadata do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    # Reset per-request keys so a reused Cowboy/Bandit worker cannot inherit
    # the previous request's user_id.
    Logger.metadata(user_id: nil)

    if user = conn.assigns[:current_user] do
      Logger.metadata(user_id: user.id)
    end

    conn
  end
end
