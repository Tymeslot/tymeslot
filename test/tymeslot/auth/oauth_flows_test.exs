defmodule Tymeslot.Auth.OAuthFlowsTest do
  @moduledoc """
  Comprehensive behavior tests for OAuth authentication flows.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Auth.OAuth.UserProcessor
  alias Tymeslot.Auth.SocialAuthentication

  # =====================================
  # Email Availability Behaviors
  # =====================================

  describe "when checking email availability" do
    test "accepts unregistered email" do
      result = SocialAuthentication.check_email_availability("available@example.com")
      assert result == :ok
    end

    test "rejects already registered email" do
      insert(:user, email: "taken@example.com")

      result = SocialAuthentication.check_email_availability("taken@example.com")
      assert {:error, message} = result
      assert message =~ "already registered"
    end
  end

  # =====================================
  # Process User Info Behaviors
  # =====================================

  describe "when processing GitHub user info" do
    test "handles GitHub response without email" do
      github_response = %{
        "id" => 12_345,
        "email" => nil,
        "name" => "Private User"
      }

      result = UserProcessor.process_user(:github, github_response)

      assert {:ok, user} = result
      assert user.email == nil
      assert user.github_user_id == 12_345
      assert user.email_from_provider == false
    end

    test "handles GitHub response with empty email" do
      github_response = %{
        "id" => 12_345,
        "email" => "",
        "name" => "Private User"
      }

      result = UserProcessor.process_user(:github, github_response)

      assert {:ok, user} = result
      # Empty string email is normalized to nil
      assert user.email == nil
      assert user.email_from_provider == false
    end
  end

  # =====================================
  # OAuth Client Building Behaviors
  # =====================================

  # These two are the only tests that run the real `Client.build/3` and
  # `OAuth2.Client.new/1`; every other OAuth test stubs the helper through Mox.
  # They therefore have to pin the whole client, not just the state parameter:
  # a wrong authorize_url or token_url silently sends users to the wrong
  # provider, and a missing User-Agent makes GitHub reject the request.
  describe "when building OAuth client" do
    test "builds GitHub OAuth client with state" do
      redirect_uri = "http://localhost:4000/auth/github/callback"
      state = "test-state-123"

      client = OAuthHelper.build_oauth_client(:github, redirect_uri, state)

      assert %OAuth2.Client{
               strategy: OAuth2.Strategy.AuthCode,
               redirect_uri: ^redirect_uri,
               params: %{"state" => ^state},
               site: "https://github.com",
               authorize_url: "https://github.com/login/oauth/authorize",
               token_url: "https://github.com/login/oauth/access_token"
             } = client

      assert {"User-Agent", "Tymeslot-Scheduler"} in client.headers
    end

    test "builds Google OAuth client with state" do
      redirect_uri = "http://localhost:4000/auth/google/callback"
      state = "test-state-456"

      client = OAuthHelper.build_oauth_client(:google, redirect_uri, state)

      assert %OAuth2.Client{
               strategy: OAuth2.Strategy.AuthCode,
               redirect_uri: ^redirect_uri,
               params: %{"state" => ^state},
               site: "https://accounts.google.com",
               authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
               token_url: "https://oauth2.googleapis.com/token"
             } = client

      assert {"User-Agent", "Tymeslot-Scheduler"} in client.headers
    end
  end

  describe "when getting callback URLs" do
    test "returns GitHub callback path" do
      path = OAuthHelper.get_callback_url(:github)

      assert path =~ "github"
      assert path =~ "callback"
    end

    test "returns Google callback path" do
      path = OAuthHelper.get_callback_url(:google)

      assert path =~ "google"
      assert path =~ "callback"
    end
  end
end
