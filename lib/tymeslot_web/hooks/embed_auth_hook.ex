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

  alias Tymeslot.Embed.Token
  alias Tymeslot.Profiles

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
        case Profiles.get_profile_by_username(username) do
          %{allowed_embed_domains: domains} ->
            if origin_allowed?(origin_url, domains) do
              :ok
            else
              {:error, :origin_not_allowed}
            end

          nil ->
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
        Enum.any?(allowed_domains, &domain_matches_host?(&1, host))

      _other ->
        false
    end
  end

  # Checks whether a whitelisted domain matches the request host.
  # Automatically treats `example.com` and `www.example.com` as equivalent
  # so users don't need to whitelist both variants.
  defp domain_matches_host?(domain, host) do
    case domain do
      ^host ->
        true

      "*." <> suffix ->
        # *.example.com matches sub.example.com but not example.com itself
        String.ends_with?(host, "." <> suffix) and host != "." <> suffix

      "www." <> bare ->
        # www.example.com also matches example.com
        bare == host

      _bare_domain ->
        # example.com also matches www.example.com
        "www." <> domain == host
    end
  end
end
