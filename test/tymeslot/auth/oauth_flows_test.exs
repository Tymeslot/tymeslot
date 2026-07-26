defmodule Tymeslot.Auth.OAuthFlowsTest do
  @moduledoc """
  Comprehensive behavior tests for OAuth authentication flows.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Plug.Conn
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Auth.OAuth.State
  alias Tymeslot.Auth.OAuth.UserProcessor
  alias Tymeslot.Auth.SocialAuthentication

  # =====================================
  # OAuth State Management Behaviors
  # =====================================

  describe "when generating OAuth state for CSRF protection" do
    test "generates unique state for each request" do
      conn = build_test_conn()

      {_conn1, state1} = State.generate_and_store_state(conn)
      {_conn2, state2} = State.generate_and_store_state(conn)

      assert state1 != state2
      assert String.length(state1) > 20
      assert String.length(state2) > 20
    end

    test "stores state in session" do
      conn = build_test_conn()

      {conn, state} = State.generate_and_store_state(conn)

      {stored_state, _timestamp} = Conn.get_session(conn, "_oauth_state")
      assert stored_state == state
    end
  end

  describe "when validating OAuth state" do
    test "accepts valid matching state" do
      conn = build_test_conn()
      {conn, state} = State.generate_and_store_state(conn)

      result = State.validate_state(conn, state)

      assert result == :ok
    end

    test "rejects mismatching state" do
      conn = build_test_conn()
      {conn, _state} = State.generate_and_store_state(conn)

      result = State.validate_state(conn, "wrong-state")

      assert {:error, :invalid_state} = result
    end

    test "rejects nil state parameter" do
      conn = build_test_conn()
      {conn, _state} = State.generate_and_store_state(conn)

      result = State.validate_state(conn, nil)

      assert {:error, :invalid_state} = result
    end

    test "rejects empty state parameter" do
      conn = build_test_conn()
      {conn, _state} = State.generate_and_store_state(conn)

      result = State.validate_state(conn, "")

      assert {:error, :invalid_state} = result
    end
  end

  describe "when clearing OAuth state" do
    test "removes state from session" do
      conn = build_test_conn()
      {conn, state} = State.generate_and_store_state(conn)

      # Verify state exists — stored alongside the issue timestamp
      assert {^state, issued_at} = Conn.get_session(conn, "_oauth_state")
      assert is_integer(issued_at)

      # Clear state
      conn = State.clear_oauth_state(conn)

      # Verify state is removed
      assert Conn.get_session(conn, "_oauth_state") == nil
    end
  end

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
    test "extracts user data from GitHub response" do
      github_response = %{
        "id" => 12_345,
        "email" => "github_user@example.com",
        "name" => "GitHub User"
      }

      result = UserProcessor.process_user(:github, github_response)

      assert {:ok, user} = result
      assert user.email == "github_user@example.com"
      assert user.github_user_id == 12_345
      assert user.name == "GitHub User"
      assert user.is_verified == true
      assert user.email_from_provider == true
    end

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

  describe "when processing Google user info" do
    test "extracts user data from Google response" do
      google_response = %{
        "id" => "google_id_123",
        "email" => "google_user@gmail.com",
        "name" => "Google User"
      }

      result = UserProcessor.process_user(:google, google_response)

      assert {:ok, user} = result
      assert user.email == "google_user@gmail.com"
      assert user.google_user_id == "google_id_123"
      assert user.name == "Google User"
      assert user.is_verified == true
      assert user.email_from_provider == true
    end
  end

  # =====================================
  # OAuth Client Building Behaviors
  # =====================================

  describe "when building OAuth client" do
    test "builds GitHub OAuth client with state" do
      redirect_uri = "http://localhost:4000/auth/github/callback"
      state = "test-state-123"

      client = OAuthHelper.build_oauth_client(:github, redirect_uri, state)

      assert %OAuth2.Client{redirect_uri: ^redirect_uri, params: %{"state" => ^state}} = client
    end

    test "builds Google OAuth client with state" do
      redirect_uri = "http://localhost:4000/auth/google/callback"
      state = "test-state-456"

      client = OAuthHelper.build_oauth_client(:google, redirect_uri, state)

      assert %OAuth2.Client{redirect_uri: ^redirect_uri, params: %{"state" => ^state}} = client
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

  # =====================================
  # Helper Functions
  # =====================================

  defp build_test_conn do
    PlugTest.init_test_session(PlugTest.conn(:get, "/"), %{})
  end
end
