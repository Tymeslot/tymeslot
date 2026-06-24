defmodule TymeslotWeb.EmbedBlockedController do
  @moduledoc """
  Renders the public, content-free "this booking page can't be embedded here"
  notice shown inside the iframe when an embed request comes from an origin the
  organiser hasn't allow-listed.

  Core's embed-auth hook (`TymeslotWeb.Hooks.EmbedAuthHook`) redirects a
  rejected embedded render here instead of to the marketing homepage, so a
  blocked embed never leaks unrelated marketing content into the embedding
  site. When the parent origin is known it is passed through so the page can
  post a `tymeslot-embed-blocked` message to the embedder — letting integrations
  such as the official WordPress plugin replace the frame with their own
  message immediately.

  Served through the `:embed_notice` pipeline, which runs
  `SecurityHeadersPlug` in `:any` mode so this page (and only this page) frames
  on any origin.
  """
  use TymeslotWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:index, parent_origin: sanitise_origin(params["parent-origin"]))
  end

  # Re-validate the parent origin arriving via the query string (defence in
  # depth — the hook already verified it) and reduce it to a bare
  # scheme://host[:port] origin before it reaches the page.
  defp sanitise_origin(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      _other ->
        nil
    end
  end

  defp sanitise_origin(_value), do: nil
end
