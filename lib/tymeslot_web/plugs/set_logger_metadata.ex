defmodule TymeslotWeb.Plugs.SetLoggerMetadata do
  @moduledoc false

  require Logger

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if user = conn.assigns[:current_user] do
      Logger.metadata(user_id: user.id)
    end

    conn
  end
end
