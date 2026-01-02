defmodule Tymeslot.Integrations.Calendar.OAuthTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.OAuth

  # Make sure mocks are verified
  setup :verify_on_exit!

  describe "initiate_google_oauth/1" do
    test "generates valid authorization URL with user ID using mock" do
      user = insert(:user)
      expected_url = "https://accounts.google.com/o/oauth2/v2/auth?client_id=test&state=#{user.id}"

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri -> expected_url end)

      assert {:ok, ^expected_url} = OAuth.initiate_google_oauth(user.id)
    end

    test "returns error when mock helper raises configuration error" do
      user = insert(:user)

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _, _ ->
        raise "Client ID not configured"
      end)

      assert {:error, message} = OAuth.initiate_google_oauth(user.id)
      assert String.contains?(message, "Google OAuth is not configured")
      assert String.contains?(message, "GOOGLE_CLIENT_ID")
    end
  end

  describe "initiate_outlook_oauth/1" do
    test "generates valid authorization URL with user ID using mock" do
      user = insert(:user)
      expected_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=test"

      expect(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id, _redirect_uri -> expected_url end)

      assert {:ok, ^expected_url} = OAuth.initiate_outlook_oauth(user.id)
    end

    test "returns error when mock helper raises configuration error" do
      user = insert(:user)

      expect(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _, _ ->
        raise "Client ID not configured"
      end)

      assert {:error, message} = OAuth.initiate_outlook_oauth(user.id)
      assert String.contains?(message, "Outlook OAuth is not configured")
      assert String.contains?(message, "OUTLOOK_CLIENT_ID")
    end
  end

  describe "initiate_google_scope_upgrade/2" do
    test "initiates scope upgrade using mock" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")
      expected_url = "https://accounts.google.com/upgrade"

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _, _ -> expected_url end)

      assert {:ok, ^expected_url} = OAuth.initiate_google_scope_upgrade(user.id, integration.id)
    end

    test "returns error when integration is not found" do
      user = insert(:user)
      non_existent_id = 99_999

      assert {:error, :not_found} = OAuth.initiate_google_scope_upgrade(user.id, non_existent_id)
    end

    test "returns error when integration is not Google provider" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "caldav")

      assert {:error, :invalid_provider} =
               OAuth.initiate_google_scope_upgrade(user.id, integration.id)
    end
  end

  describe "needs_scope_upgrade?/1" do
    test "returns false for non-Google integrations" do
      integration = %{provider: "caldav"}
      refute OAuth.needs_scope_upgrade?(integration)
    end
  end

  describe "format_oauth_error/2" do
    test "formats state secret configuration error for Google" do
      error = %RuntimeError{message: "State Secret not configured"}
      message = OAuth.format_oauth_error(error, "Google")

      assert String.contains?(message, "Google OAuth is not configured")
      assert String.contains?(message, "GOOGLE_STATE_SECRET")
    end

    test "formats client ID configuration error" do
      error = %RuntimeError{message: "Client ID not configured"}
      message = OAuth.format_oauth_error(error, "Outlook")

      assert String.contains?(message, "Outlook OAuth is not configured")
      assert String.contains?(message, "OUTLOOK_CLIENT_ID")
    end

    test "formats generic runtime errors" do
      error = %RuntimeError{message: "Something went wrong"}
      message = OAuth.format_oauth_error(error, "Google")

      assert String.contains?(message, "Failed to setup Google OAuth")
      assert String.contains?(message, "Something went wrong")
    end
  end
end
