defmodule TymeslotWeb.Plugs.SecurityHeadersPlug do
  @moduledoc """
  Adds comprehensive security headers to all responses.
  Supports domain whitelisting for embedding via the profile's allowed_embed_domains field.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Tymeslot.Profiles
  alias TymeslotWeb.Helpers.PathUtils

  @local_hosts ~w(localhost 127.0.0.1 ::1)

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, opts) do
    allow_embedding = Keyword.get(opts, :allow_embedding, false)

    # Per-request CSP nonce. Generated here so the same plug that builds the
    # CSP header also owns the value the templates render — a page either gets
    # both the header and the nonce assign, or neither, so they can never drift.
    nonce = generate_nonce()
    conn = assign(conn, :csp_nonce, nonce)

    # Determine frame-ancestors based on the profile's allowed domains.
    # CSP frame-ancestors is the primary source of truth for modern browsers.
    {frame_ancestors, x_frame_options} =
      if allow_embedding do
        get_embed_security_headers(conn)
      else
        {"'none'", "DENY"}
      end

    conn =
      conn
      |> put_resp_header("content-security-policy", csp_header(frame_ancestors, nonce))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
      |> put_resp_header("permissions-policy", permissions_policy())
      |> put_resp_header(
        "strict-transport-security",
        "max-age=31536000; includeSubDomains; preload"
      )

    if x_frame_options do
      put_resp_header(conn, "x-frame-options", x_frame_options)
    else
      # If X-Frame-Options is nil, we omit it to let CSP frame-ancestors
      # be the sole authority for modern browsers.
      conn
    end
  end

  # Extracts username from path and retrieves allowed embed domains
  # Returns {frame_ancestors, x_frame_options | nil}
  defp get_embed_security_headers(conn) do
    conn = fetch_query_params(conn)
    is_preview = conn.query_params["preview"] in ["true", "1"]
    username = PathUtils.extract_username_from_path(conn.request_path)

    case username do
      nil ->
        # No username in path; default to blocking embedding.
        # (We don't want "allow all embedding" as a fallback.)
        Logger.debug("No username in path, blocking embedding", path: conn.request_path)
        {"'none'", "DENY"}

      username ->
        case Profiles.get_profile_by_username(username) do
          %{} = profile ->
            {frame_ancestors, x_frame_options} =
              build_security_headers(profile.allowed_embed_domains, is_preview)

            # Log when embedding is restricted (skip nil/[]/["none"] — those deny all)
            if profile.allowed_embed_domains not in [nil, [], ["none"]] do
              referer = List.first(get_req_header(conn, "referer"))

              Logger.info("Embed security restrictions applied",
                username: username,
                profile_id: profile.id,
                allowed_domains: profile.allowed_embed_domains,
                referer: referer
              )
            end

            {frame_ancestors, x_frame_options}

          nil ->
            {"'none'", "DENY"}
        end
    end
  end

  # Builds the security headers based on allowed domains.
  # CSP frame-ancestors is the sole embedding authority for modern browsers.
  # X-Frame-Options is only set for non-embed pages (DENY or SAMEORIGIN).
  # Returns {frame_ancestors, x_frame_options | nil}
  defp build_security_headers(allowed_domains, true)
       when allowed_domains in [nil, [], ["none"]] do
    # Allow same-origin framing for dashboard "Live Preview" (iframe),
    # while still blocking embedding from other origins.
    {"'self'", "SAMEORIGIN"}
  end

  defp build_security_headers([], _is_preview), do: dev_local_or_deny()
  defp build_security_headers(nil, _is_preview), do: dev_local_or_deny()
  defp build_security_headers(["none"], _is_preview), do: dev_local_or_deny()

  defp build_security_headers(allowed_domains, _is_preview) when is_list(allowed_domains) do
    if "none" in allowed_domains do
      dev_local_or_deny()
    else
      is_dev_env = Application.get_env(:tymeslot, :environment) in [:dev, :test]

      # Build CSP frame-ancestors with appropriate protocols.
      # Modern browsers prioritize this over X-Frame-Options.
      # Expand each domain to include its www variant so users don't
      # need to whitelist both example.com and www.example.com.
      expanded_domains = Enum.flat_map(allowed_domains, &expand_www_variant/1)

      domains =
        Enum.map_join(expanded_domains, " ", fn domain ->
          if domain in @local_hosts and is_dev_env do
            "http://#{domain}:*"
          else
            "https://#{domain}"
          end
        end)

      frame_ancestors = "'self' #{domains}#{dev_localhost_suffix(allowed_domains, is_dev_env)}"

      # X-Frame-Options ALLOW-FROM is deprecated and unsupported in modern browsers.
      # When frame-ancestors is present in CSP, browsers ignore X-Frame-Options and
      # log a console warning. Omit it entirely to keep the console clean.
      {frame_ancestors, nil}
    end
  end

  # In dev/test, allow localhost embedding without requiring it in allowed_embed_domains.
  # In production this always returns {"'none'", "DENY"}.
  defp dev_local_or_deny do
    if Application.get_env(:tymeslot, :environment) in [:dev, :test] do
      {"'self' http://localhost:* http://127.0.0.1:*", nil}
    else
      {"'none'", "DENY"}
    end
  end

  # Appends localhost origins in dev/test when not already in the allowed list.
  defp dev_localhost_suffix(allowed_domains, is_dev_env) do
    if is_dev_env and not Enum.any?(allowed_domains, &(&1 in @local_hosts)) do
      " http://localhost:* http://127.0.0.1:*"
    else
      ""
    end
  end

  defp analytics_script_origins do
    providers = Application.get_env(:tymeslot, :analytics_providers, []) || []

    providers
    |> Enum.flat_map(fn
      %{script_url: url} when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
            ["#{scheme}://#{host}"]

          _uri ->
            []
        end

      _provider ->
        []
    end)
    |> Enum.uniq()
  end

  # 18 random bytes → 24-char base64url. Enough entropy to make the nonce
  # unguessable per request, which is the whole point of a CSP nonce.
  defp generate_nonce do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp csp_header(frame_ancestors, nonce) do
    extra_script_origins = analytics_script_origins()

    script_src =
      Enum.join(
        [
          "'self'",
          "'nonce-#{nonce}'",
          "https://www.google.com",
          "https://www.gstatic.com",
          "https://js.stripe.com"
        ] ++ extra_script_origins,
        " "
      )

    extra_connect_suffix =
      case extra_script_origins do
        [] -> ""
        origins -> " " <> Enum.join(origins, " ")
      end

    connect_src =
      if Application.get_env(:tymeslot, :environment) == :dev do
        "'self' ws://localhost:* ws://127.0.0.1:* http://localhost:* http://127.0.0.1:* ws: wss: https://www.google.com https://accounts.google.com https://api.stripe.com" <>
          extra_connect_suffix
      else
        "'self' wss: https://www.google.com https://accounts.google.com https://api.stripe.com" <>
          extra_connect_suffix
      end

    Enum.join(
      [
        "default-src 'self'",
        # Inline scripts are authorised by a per-request nonce; reCAPTCHA +
        # Stripe require their external origins.
        "script-src #{script_src}",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "img-src 'self' data: https:",
        "font-src 'self' data: https://fonts.gstatic.com",
        # Allow connections to reCAPTCHA, Google services, and Stripe
        "connect-src #{connect_src}",
        # Allow reCAPTCHA and Stripe frames
        "frame-src 'self' https://www.google.com https://accounts.google.com https://js.stripe.com https://hooks.stripe.com",
        "frame-ancestors #{frame_ancestors}",
        "base-uri 'self'",
        "form-action 'self' https://billing.stripe.com https://checkout.stripe.com"
      ],
      "; "
    )
  end

  # Returns both the domain and its www counterpart so CSP frame-ancestors
  # covers both variants. Wildcards and localhost are returned as-is.
  defp expand_www_variant("www." <> bare = domain) do
    [domain, bare]
  end

  defp expand_www_variant("*." <> _rest = domain), do: [domain]

  defp expand_www_variant(domain) when domain in @local_hosts do
    [domain]
  end

  defp expand_www_variant(domain) do
    [domain, "www." <> domain]
  end

  defp permissions_policy do
    Enum.join(
      [
        "camera=()",
        "microphone=()",
        "geolocation=()"
      ],
      ", "
    )
  end
end
