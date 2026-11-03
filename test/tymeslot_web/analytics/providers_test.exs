defmodule TymeslotWeb.Analytics.ProvidersTest do
  @moduledoc """
  The layout renders a loader script per analytics provider and the CSP plug
  allows each provider's origin. These pin that both read the same validated
  list, so a script the page renders is never blocked by the policy and the
  policy never allows an origin no script loads from.
  """

  # async: false — mutates the global :analytics_providers app env.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :analytics
  @moduletag :security

  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias TymeslotWeb.Analytics.Providers

  @non_default_port %{
    provider: :umami,
    script_url: "https://stats.example.com:8443/script.js",
    website_id: "port"
  }
  @same_origin %{provider: :umami, script_url: "/stats/script.js", website_id: "local"}
  @shared_host_a %{
    provider: :umami,
    script_url: "https://analytics.example.com/a.js",
    website_id: "a"
  }
  @shared_host_b %{
    provider: :umami,
    script_url: "https://analytics.example.com/b.js",
    website_id: "b"
  }
  @no_website_id %{provider: :umami, script_url: "https://rogue.example.com/x.js"}
  @unknown_provider %{
    provider: :plausible,
    script_url: "https://plausible.example.com/js",
    website_id: "p"
  }
  @not_a_url %{provider: :umami, script_url: "javascript:alert(1)", website_id: "js"}

  @configured [
    @non_default_port,
    @same_origin,
    @shared_host_a,
    @shared_host_b,
    @no_website_id,
    @unknown_provider,
    @not_a_url
  ]

  setup do
    original = Application.get_env(:tymeslot, :analytics_providers)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :analytics_providers)
        value -> Application.put_env(:tymeslot, :analytics_providers, value)
      end
    end)

    Application.put_env(:tymeslot, :analytics_providers, @configured)
    :ok
  end

  describe "all/0" do
    test "keeps only complete umami providers with an http(s) or same-origin URL" do
      assert Providers.all() == [@non_default_port, @same_origin, @shared_host_a, @shared_host_b]
    end

    test "is empty when analytics is unconfigured" do
      Application.put_env(:tymeslot, :analytics_providers, nil)

      assert Providers.all() == []
    end
  end

  describe "origins/0" do
    test "lists each external origin once, keeping a non-default port" do
      assert Providers.origins() == [
               "https://stats.example.com:8443",
               "https://analytics.example.com"
             ]
    end
  end

  describe "rendered page and CSP header" do
    test "allow exactly the origins of the scripts the login page renders", %{conn: conn} do
      assert_page_and_policy_agree(get(conn, ~p"/auth/login"))
    end

    test "allow exactly the origins of the scripts a booking page renders", %{conn: conn} do
      %{profile: profile} = seed_booking_account("1", "analytics-host", "Etc/UTC")

      assert_page_and_policy_agree(get(conn, "/#{profile.username}"))
    end
  end

  defp assert_page_and_policy_agree(conn) do
    html = html_response(conn, 200)
    [csp] = get_resp_header(conn, "content-security-policy")
    script_src = directive(csp, "script-src")

    rendered_srcs =
      ~r/data-analytics-src="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()

    assert rendered_srcs == [
             "https://stats.example.com:8443/script.js",
             "/stats/script.js",
             "https://analytics.example.com/a.js",
             "https://analytics.example.com/b.js"
           ]

    expected_origins = ["https://stats.example.com:8443", "https://analytics.example.com"]

    assert analytics_sources(script_src, conn.assigns.csp_nonce) == expected_origins
    assert analytics_sources(directive(csp, "connect-src"), nil) == expected_origins
  end

  defp directive(csp, name) do
    csp
    |> String.split("; ")
    |> Enum.find(&String.starts_with?(&1, name <> " "))
    |> String.split(" ")
    |> tl()
  end

  # Sources other than 'self', the nonce, the reCAPTCHA hosts and the socket.
  defp analytics_sources(sources, nonce) do
    Enum.reject(sources, fn source ->
      source in ["'self'", "'nonce-#{nonce}'"] or
        String.contains?(source, ["google.com", "gstatic.com", "localhost", "127.0.0.1"]) or
        String.starts_with?(source, "ws")
    end)
  end
end
