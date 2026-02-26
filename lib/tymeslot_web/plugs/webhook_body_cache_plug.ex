defmodule TymeslotWeb.Plugs.WebhookBodyCachePlug do
  @moduledoc """
  A plug utility that caches the raw request body for webhook endpoints.
  Used as a :body_reader for Plug.Parsers in the endpoint.
  """

  require Logger
  alias Plug.Conn

  @doc """
  Custom body reader that caches the raw body for webhook paths.
  This should be used in Plug.Parsers configuration.
  """
  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()} | {:error, any()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = maybe_cache_body(conn, body)
        {:ok, body, conn}

      other ->
        other
    end
  end

  defp maybe_cache_body(conn, body) do
    if matches_webhook_path?(conn.request_path) do
      Logger.debug("WebhookBodyCachePlug: Caching raw body", path: conn.request_path)
      Conn.assign(conn, :raw_body, body)
    else
      conn
    end
  end

  defp matches_webhook_path?(request_path) do
    Enum.any?(webhook_paths(), fn path -> path == request_path end)
  end

  defp webhook_paths do
    Application.get_env(:tymeslot, :webhook_paths, ["/api/webhook/stripe"])
  end
end
