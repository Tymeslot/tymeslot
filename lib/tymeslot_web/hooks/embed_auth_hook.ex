defmodule TymeslotWeb.Hooks.EmbedAuthHook do
  @moduledoc """
  Verifies embed tokens and embedding origin on LiveView mount.

  When an embed token is present in the session (set by `EmbedTokenPlug`
  via the router's session function), this hook:
  1. Verifies the token signature and expiry
  2. Checks the signed parent origin against the profile's allowed domains
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
  def on_mount(:default, params, session, socket) do
    embed_token = session["embed_token"]

    if embed_token do
      handle_embedded(embed_token, preview?(params), socket)
    else
      {:cont, socket}
    end
  end

  # The dashboard "Live Preview" iframe loads the booking page with
  # ?preview=true&embed=1 from tymeslot's own origin, so it is always
  # same-origin. It is exempt from the application-level third-party embed
  # allowlist (`verify_embedding/2`) on the connected render.
  #
  # SECURITY — enforcement on preview requests rests SOLELY on CSP. When
  # `?preview=true` is set, SecurityHeadersPlug pins `frame-ancestors 'self'`
  # (and X-Frame-Options SAMEORIGIN), so the browser refuses to frame the page
  # from any cross-origin site even though this hook skips the allowlist check.
  # The flag cannot be abused to embed a profile's page on a disallowed origin.
  # This CSP-only guarantee is locked in by the regression test
  # "preview=true does NOT open framing to a disallowed third-party origin" in
  # security_headers_plug_test.exs.
  defp preview?(params), do: params["preview"] in ["true", "1"]

  defp handle_embedded(embed_token, preview?, socket) do
    case Token.verify(embed_token) do
      {:ok, {username, parent_origin}} ->
        cond do
          # Disconnected (static) render — origin verification is deferred to the
          # WebSocket phase.
          not connected?(socket) ->
            {:cont, assign(socket, :embedded, true)}

          # Same-origin dashboard preview — skip the third-party allowlist so a
          # freshly created account (no allowed_embed_domains yet) can still see
          # its own live preview instead of being redirected to the
          # embed-unavailable notice.
          preview? ->
            {:cont, assign(socket, :embedded, true)}

          # On the connected (WebSocket) render, verify the signed parent_origin
          # (set by embed.js at HTTP request time) against the profile's allowed
          # domains. The WebSocket Origin header always reflects tymeslot's own
          # origin when running inside an iframe, so parent_origin from the signed
          # token is the correct value to check.
          true ->
            case verify_embedding(username, parent_origin) do
              :ok ->
                {:cont, assign(socket, :embedded, true)}

              {:error, reason} ->
                Logger.warning("Embed auth rejected",
                  reason: reason,
                  parent_origin: parent_origin
                )

                {:halt, redirect(socket, to: embed_unavailable_path(parent_origin))}
            end
        end

      {:error, reason} ->
        Logger.warning("Embed auth rejected", reason: reason)
        {:halt, redirect(socket, to: embed_unavailable_path(nil))}
    end
  end

  # Where a rejected embedded render is sent. This dedicated notice replaces the
  # old redirect to "/" (the marketing homepage), which would otherwise render
  # inside the embedding site. The parent origin is forwarded so the notice can
  # post `tymeslot-embed-blocked` back to the embedder.
  defp embed_unavailable_path(parent_origin) when is_binary(parent_origin) do
    "/embed-unavailable?" <> URI.encode_query(%{"parent-origin" => parent_origin})
  end

  defp embed_unavailable_path(_parent_origin), do: "/embed-unavailable"

  defp verify_embedding(_username, nil), do: {:error, :missing_origin}

  defp verify_embedding(username, parent_origin) do
    case Profiles.get_profile_by_username(username) do
      %{allowed_embed_domains: domains} ->
        if origin_allowed?(parent_origin, domains),
          do: :ok,
          else: {:error, :origin_not_allowed}

      nil ->
        {:error, :profile_not_found}
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
