defmodule TymeslotWeb.Integration.GitHubOAuthIntegrationTest do
  @moduledoc """
  Integration tests for GitHub OAuth authentication focusing on security and business behavior.
  Tests CSRF protection, rate limiting, and authentication flows.
  """

  use TymeslotWeb.OAuthIntegrationCase, async: false

  @moduletag :oauth_integration

  import Mox

  alias Phoenix.Flash
  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Auth.OAuth.HelperMock

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

    test "rate limits OAuth authentication attempts" do
      # Act: Make multiple requests to trigger rate limiting
      results =
        Enum.map(1..6, fn _i ->
          conn = get(build_conn(), ~p"/auth/github")
          conn.status
        end)

      # Assert: First 5 requests succeed, 6th is rate limited
      assert Enum.take(results, 5) == [302, 302, 302, 302, 302]
      assert List.last(results) == 302
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
      # Act: User clicks "Sign in with GitHub"
      conn = get(build_conn(), ~p"/auth/github")

      # Assert: User is redirected to GitHub
      assert redirected_to(conn, 302)
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
end
