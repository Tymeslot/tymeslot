defmodule Tymeslot.Auth.OAuth.URLs do
  @moduledoc """
  URL helpers for OAuth callback paths and absolute URLs.
  """

  @doc """
  Returns the callback path for a given provider.
  """
  @spec callback_path(:github | :google) :: String.t()
  def callback_path(:github), do: "/auth/github/callback"
  def callback_path(:google), do: "/auth/google/callback"

  @doc """
  Builds a full callback URL from the connection and relative path.

  If Phoenix endpoint is present, uses it; otherwise constructs from conn.
  """
  @spec callback_url(Plug.Conn.t(), String.t()) :: String.t()
  def callback_url(conn, relative_path) do
    endpoint_module = conn.private[:phoenix_endpoint]

    if endpoint_module do
      base_url = endpoint_module.url()
      "#{base_url}#{relative_path}"
    else
      scheme = if conn.scheme == :https, do: "https", else: "http"
      host = conn.host
      port = conn.port

      base_url =
        case {scheme, port} do
          {"https", 443} -> "https://#{host}"
          {"http", 80} -> "http://#{host}"
          _ -> "#{scheme}://#{host}:#{port}"
        end

      "#{base_url}#{relative_path}"
    end
  end
end
