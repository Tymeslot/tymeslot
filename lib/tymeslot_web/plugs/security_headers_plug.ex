defmodule TymeslotWeb.Plugs.SecurityHeadersPlug do
  @moduledoc """
  Adds comprehensive security headers to all responses.
  Supports domain whitelisting for embedding via the profile's allowed_embed_domains field.
  """

  import Plug.Conn

  require Logger
  alias Tymeslot.DatabaseQueries.ProfileQueries

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, opts) do
    allow_embedding = Keyword.get(opts, :allow_embedding, false)

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
      |> put_resp_header("content-security-policy", csp_header(frame_ancestors))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
      |> put_resp_header("permissions-policy", permissions_policy())
      |> put_resp_header("strict-transport-security", "max-age=31536000; includeSubDomains")
      |> put_resp_header("x-xss-protection", "1; mode=block")
      |> put_resp_header("expect-ct", "max-age=86400, enforce")

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
    username = extract_username_from_path(conn.request_path)

    case username do
      nil ->
        # No username in path; default to blocking embedding.
        # (We don't want "allow all embedding" as a fallback.)
        Logger.debug("No username in path, blocking embedding", path: conn.request_path)
        {"'none'", "DENY"}

      username ->
        case ProfileQueries.get_by_username(username) do
          {:ok, profile} ->
            {frame_ancestors, x_frame_options} =
              build_security_headers(profile.allowed_embed_domains, is_preview)

            # Log when embedding is restricted
            if profile.allowed_embed_domains != [] do
              referer = List.first(get_req_header(conn, "referer"))

              Logger.info("Embed security restrictions applied",
                username: username,
                profile_id: profile.id,
                allowed_domains: inspect(profile.allowed_embed_domains),
                referer: referer
              )
            end

            {frame_ancestors, x_frame_options}

          {:error, :not_found} ->
            # Profile not found; default to blocking embedding.
            Logger.warning("Profile not found for username, blocking embedding",
              username: username,
              path: conn.request_path
            )

            {"'none'", "DENY"}
        end
    end
  end

  # Extracts username from scheduling paths like /:username or /:username/...
  defp extract_username_from_path(path) do
    # List of reserved paths that can't be usernames
    reserved_paths = [
      "",
      "auth",
      "dashboard",
      "api",
      "dev",
      "assets",
      "docs",
      "admin",
      "healthcheck",
      "robots.txt",
      "sitemap.xml",
      "favicon.ico",
      "embed.js"
    ]

    case String.split(path, "/", parts: 3) do
      ["", username | _rest] ->
        if username in reserved_paths, do: nil, else: username

      _invalid_path ->
        nil
    end
  end

  # Builds the security headers based on allowed domains.
  # CSP frame-ancestors is the primary security mechanism for modern browsers.
  # X-Frame-Options is provided as a best-effort fallback for legacy browsers.
  # Returns {frame_ancestors, x_frame_options | nil}
  defp build_security_headers(allowed_domains, true)
       when allowed_domains in [nil, [], ["none"]] do
    # Allow same-origin framing for dashboard "Live Preview" (iframe),
    # while still blocking embedding from other origins.
    {"'self'", "SAMEORIGIN"}
  end

  defp build_security_headers([], _is_preview), do: {"'none'", "DENY"}
  defp build_security_headers(nil, _is_preview), do: {"'none'", "DENY"}
  defp build_security_headers(["none"], _is_preview), do: {"'none'", "DENY"}

  defp build_security_headers(allowed_domains, _is_preview) when is_list(allowed_domains) do
    if "none" in allowed_domains do
      {"'none'", "DENY"}
    else
      # Build CSP frame-ancestors with appropriate protocols.
      # Modern browsers prioritize this over X-Frame-Options.
      domains =
        Enum.map_join(allowed_domains, " ", fn domain ->
          is_local = domain in ["localhost", "127.0.0.1", "::1"]
          is_dev = Application.get_env(:tymeslot, :environment) in [:dev, :test]

          if is_local and is_dev do
            "http://#{domain}:*"
          else
            "https://#{domain}"
          end
        end)

      frame_ancestors = "'self' #{domains}"

      # X-Frame-Options ALLOW-FROM is deprecated and only supports a single domain.
      # It is provided only for defense-in-depth for legacy browsers (IE, old Firefox).
      # Chrome, Safari, and modern Firefox ignore it.
      x_frame_options =
        case allowed_domains do
          [first_domain | _rest] ->
            # X-Frame-Options ALLOW-FROM does not support wildcards or multiple domains.
            # Modern browsers use CSP frame-ancestors anyway.
            if String.starts_with?(first_domain, "*") do
              nil
            else
              is_local = first_domain in ["localhost", "127.0.0.1", "::1"]
              is_dev = Application.get_env(:tymeslot, :environment) in [:dev, :test]

              if is_local and is_dev do
                "ALLOW-FROM http://#{first_domain}"
              else
                "ALLOW-FROM https://#{first_domain}"
              end
            end
        end

      {frame_ancestors, x_frame_options}
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

          _ ->
            []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp csp_header(frame_ancestors) do
    extra_script_origins = analytics_script_origins()

    script_src =
      (["'self'", "'unsafe-inline'", "'unsafe-eval'", "https://www.google.com",
        "https://www.gstatic.com", "https://js.stripe.com"] ++ extra_script_origins)
      |> Enum.join(" ")

    connect_src =
      if Application.get_env(:tymeslot, :environment) == :dev do
        "'self' ws://localhost:* ws://127.0.0.1:* http://localhost:* http://127.0.0.1:* ws: wss: https://www.google.com https://accounts.google.com https://api.stripe.com"
      else
        "'self' wss: https://www.google.com https://accounts.google.com https://api.stripe.com"
      end

    Enum.join(
      [
        "default-src 'self'",
        # Phoenix LiveView requires unsafe-inline, reCAPTCHA + Stripe require external domains
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
        "form-action 'self'"
      ],
      "; "
    )
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
