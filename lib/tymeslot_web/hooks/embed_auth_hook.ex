defmodule TymeslotWeb.Hooks.EmbedAuthHook do
  @moduledoc """
  Verifies embed tokens and embedding origin on LiveView mount.

  When an embed token is present in the session (set by `EmbedTokenPlug`
  via the router's session function), this hook:
  1. Verifies the token signature and expiry
  2. Checks the WebSocket `Origin` header against the profile's allowed domains
  3. Sets `socket.assigns.embedded` to `true` on success

  When no embed token is present (non-embedded pages), the hook passes through.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  require Logger

  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Embed.Token

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    embed_token = session["embed_token"]

    if embed_token do
      handle_embedded(embed_token, socket)
    else
      {:cont, socket}
    end
  end

  defp handle_embedded(embed_token, socket) do
    with {:ok, username} <- Token.verify(embed_token),
         :ok <- verify_origin(socket, username) do
      {:cont, assign(socket, :embedded, true)}
    else
      {:error, reason} ->
        Logger.warning("Embed auth rejected",
          reason: reason,
          origin: get_origin_header(socket)
        )

        {:halt, redirect(socket, to: "/")}
    end
  end

  defp verify_origin(socket, username) do
    case get_origin_header(socket) do
      nil ->
        # No Origin header (same-origin or privacy settings).
        # CSP frame-ancestors already enforced on the initial HTTP request.
        :ok

      origin_url ->
        case ProfileQueries.get_by_username(username) do
          {:ok, profile} ->
            if origin_allowed?(origin_url, profile.allowed_embed_domains) do
              :ok
            else
              {:error, :origin_not_allowed}
            end

          {:error, :not_found} ->
            {:error, :profile_not_found}
        end
    end
  end

  defp get_origin_header(socket) do
    case get_connect_info(socket, :x_headers) do
      headers when is_list(headers) ->
        Enum.find_value(headers, fn
          {"origin", value} -> value
          _other -> nil
        end)

      _other ->
        nil
    end
  end

  @doc false
  @spec origin_allowed?(String.t(), list(String.t()) | nil) :: boolean()
  def origin_allowed?(_origin_url, domains) when domains in [nil, [], ["none"]], do: false

  def origin_allowed?(origin_url, allowed_domains) do
    case URI.parse(origin_url) do
      %URI{host: host} when is_binary(host) ->
        Enum.any?(allowed_domains, fn domain ->
          domain == host or
            (String.starts_with?(domain, "*.") and
               String.ends_with?(host, String.trim_leading(domain, "*")))
        end)

      _other ->
        false
    end
  end
end
