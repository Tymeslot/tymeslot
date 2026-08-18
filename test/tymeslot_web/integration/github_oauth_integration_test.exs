defmodule TymeslotWeb.Integration.GitHubOAuthIntegrationTest do
  @moduledoc """
  Integration tests for GitHub OAuth authentication focusing on security and business behavior.
  Tests CSRF protection, rate limiting, and authentication flows.
  """

  use TymeslotWeb.OAuthIntegrationCase, async: false

  @moduletag :oauth_integration
  @moduletag :auth
  @moduletag :integrations

  import Mox

  alias Phoenix.Flash
  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Auth.OAuth.HelperMock

  # `RateLimiter.OAuth.check_initiation/1` allows this many initiations per IP
  # per 600s window; the next one is refused.
  @initiation_limit 10

  # The controller resolves its callback handler through
  # `:oauth_callback_module`, which test config points at `HelperMock`. Without
  # a stub the callback raises `Mox.UnexpectedCallError` before any flash is
  # set, so stub the mock with the real implementation and let these tests
  # exercise genuine state validation.
  setup do
    stub_with(HelperMock, OAuthHelper)
    :ok
  end

  describe "GitHub OAuth Security" do
    test "prevents CSRF attacks with state parameter validation" do
      # Setup: Create session with expected state
      conn =
        build_conn()
        |> init_test_session(%{})
        |> put_session(:_oauth_state, "expected_state")

      # Act: Attempt callback with wrong state
      conn =
        get(conn, ~p"/auth/github/callback", %{
          "code" => "some_code",
          "state" => "wrong_state"
        })

      # Assert: Authentication fails due to state mismatch
      assert redirected_to(conn, 302) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Security validation failed. Please try again."
    end

    test "rate limits OAuth initiation once the per-IP allowance is spent" do
      enable_social_auth(:github_enabled)

      # Act: Spend the whole per-IP initiation allowance, then ask once more.
      allowed = Enum.map(1..@initiation_limit, fn _i -> get(build_conn(), ~p"/auth/github") end)
      blocked = get(build_conn(), ~p"/auth/github")

      # Assert: Every allowed attempt hands the visitor to GitHub, with no error
      for conn <- allowed do
        assert redirected_to(conn, 302) =~ "github.com"
        assert is_nil(Flash.get(conn.assigns.flash, :error))
      end

      # Assert: The one over the limit is turned back to the login page instead.
      # Both outcomes are 302s, so the destination and the flash are what
      # distinguish them.
      assert redirected_to(blocked, 302) == "/auth/login"

      assert Flash.get(blocked.assigns.flash, :error) ==
               "Too many OAuth attempts. Please try again later."
    end

    test "handles missing OAuth credentials gracefully" do
      # Act: Attempt callback without required code parameter
      conn = get(build_conn(), ~p"/auth/github/callback", %{"state" => "test-state"})

      # Assert: User sees appropriate error message
      assert redirected_to(conn, 302)
      assert Flash.get(conn.assigns.flash, :error) =~ "missing authorization code"
    end
  end

  describe "GitHub OAuth User Flow" do
    test "user can initiate GitHub authentication" do
      enable_social_auth(:github_enabled)
      put_env("GITHUB_CLIENT_ID", "test-github-client-id")

      # Act: User clicks "Sign in with GitHub"
      conn = get(build_conn(), ~p"/auth/github")

      # Assert: the redirect is GitHub's authorize endpoint, carrying every
      # parameter the handshake needs. A 302 on its own proves nothing here:
      # the "provider not available" and rate-limited paths are 302s too.
      uri = conn |> redirected_to(302) |> URI.parse()
      query = URI.decode_query(uri.query)
      {stored_state, _issued_at} = get_session(conn, :_oauth_state)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
               "https://github.com/login/oauth/authorize"

      assert query["client_id"] == "test-github-client-id"
      assert query["response_type"] == "code"
      assert query["scope"] == "user:email"
      assert query["redirect_uri"] =~ "/auth/github/callback"

      # The state travelling to GitHub must be the one the server stored, or
      # the callback's CSRF check could never match it.
      assert query["state"] == stored_state
      assert stored_state != ""
    end

    test "user sees error when the callback carries a state the server never issued" do
      # Act: GitHub redirects back on a session that never started a flow, so
      # there is no stored state to compare against.
      conn =
        get(build_conn(), ~p"/auth/github/callback", %{
          "code" => "invalid_code",
          "state" => "test-state"
        })

      # Assert: Rejected at state validation, before any token exchange
      assert redirected_to(conn, 302) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Security validation failed. Please try again."
    end
  end

  # Provider availability comes from env vars, so it cannot be assumed. Turn the
  # provider on for the duration of the test that needs the request to reach the
  # rate limiter rather than the "not available" redirect.
  defp enable_social_auth(provider_key) do
    original = Application.get_env(:tymeslot, :social_auth, [])
    Application.put_env(:tymeslot, :social_auth, Keyword.put(original, provider_key, true))
    on_exit(fn -> Application.put_env(:tymeslot, :social_auth, original) end)
  end

  # The OAuth client reads its credentials straight from the environment, so a
  # test that asserts on the client_id has to own the value it expects.
  defp put_env(name, value) do
    original = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(name)
        original -> System.put_env(name, original)
      end
    end)
  end
end
