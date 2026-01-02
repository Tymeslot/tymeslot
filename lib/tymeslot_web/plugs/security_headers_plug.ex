defmodule TymeslotWeb.Plugs.SecurityHeadersPlug do
  @moduledoc """
  Adds comprehensive security headers to all responses.
  """

  alias Tymeslot.Deployment
  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", csp_header())
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", permissions_policy())
    |> put_resp_header("strict-transport-security", "max-age=31536000; includeSubDomains")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("expect-ct", "max-age=86400, enforce")
  end

  defp csp_header do
    base_script_src =
      "'self' 'unsafe-inline' 'unsafe-eval' https://www.google.com https://www.gstatic.com"

    script_src =
      if Deployment.main?() && umami_script_url() do
        base_script_src <> " " <> umami_script_url()
      else
        base_script_src
      end

    base_connect_src = "'self' wss: https://www.google.com https://accounts.google.com"

    connect_src =
      if Deployment.main?() && umami_domain() do
        base_connect_src <> " " <> umami_domain()
      else
        base_connect_src
      end

    Enum.join(
      [
        "default-src 'self'",
        # Phoenix LiveView requires unsafe-inline, reCAPTCHA requires Google domains, Umami for main deployment
        "script-src #{script_src}",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "img-src 'self' data: https:",
        "font-src 'self' data: https://fonts.gstatic.com",
        # Allow connections to reCAPTCHA, Google services, and Umami for main deployment
        "connect-src #{connect_src}",
        # Allow reCAPTCHA frames from Google
        "frame-src 'self' https://www.google.com https://accounts.google.com",
        "frame-ancestors 'none'",
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

  defp umami_script_url do
    System.get_env("UMAMI_SCRIPT_URL")
  end

  defp umami_domain do
    case umami_script_url() do
      nil ->
        nil

      url ->
        uri = URI.parse(url)
        "#{uri.scheme}://#{uri.host}"
    end
  end
end
