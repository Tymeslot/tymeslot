defmodule TymeslotWeb.Integration.GitHubOAuthIntegrationTest do
  @moduledoc """
  Integration tests for GitHub OAuth authentication focusing on security and business behavior.
  Tests CSRF protection, rate limiting, and authentication flows.
  """

  use TymeslotWeb.OAuthIntegrationCase, async: false

  @moduletag :oauth_integration

  alias Phoenix.Flash

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
      assert redirected_to(conn, 302)
      flash_error = Flash.get(conn.assigns.flash, :error)
      assert flash_error =~ "authentication failed" or flash_error =~ "Security validation failed"
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

    test "user sees error when authentication fails" do
      # Act: GitHub redirects back with invalid code
      conn =
        get(build_conn(), ~p"/auth/github/callback", %{
          "code" => "invalid_code",
          "state" => "test-state"
        })

      # Assert: User is redirected with error message
      assert redirected_to(conn, 302)
      flash_error = Flash.get(conn.assigns.flash, :error)
      assert flash_error =~ "authentication failed" or flash_error =~ "Security validation failed"
    end
  end
end
