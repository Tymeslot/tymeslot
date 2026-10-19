defmodule Tymeslot.Integrations.Calendar.OAuthTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.OAuth
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias TymeslotWeb.Endpoint

  # Make sure mocks are verified
  setup :verify_on_exit!

  describe "initiate/3 for Google" do
    test "passes the user ID and the Google callback redirect URI to the helper" do
      user = insert(:user)

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn user_id, redirect_uri, opts ->
        assert user_id == user.id
        assert redirect_uri == "#{Endpoint.url()}/auth/google/calendar/callback"
        # The context starts a PKCE flow and hands the helper its challenge.
        assert [pkce: %{nonce: _nonce, code_challenge: _challenge}] = opts

        "https://accounts.google.com/o/oauth2/v2/auth?client_id=test"
      end)

      assert {:ok, _url} = OAuth.initiate(:google, user.id)
    end

    test "returns error when mock helper raises configuration error" do
      user = insert(:user)

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id,
                                                                    _redirect_uri,
                                                                    _opts ->
        raise "Client ID not configured"
      end)

      assert {:error, message} = OAuth.initiate(:google, user.id)
      assert String.contains?(message, "Google OAuth is not configured")
      assert String.contains?(message, "GOOGLE_CLIENT_ID")
    end

    test "passes return_to option through to the helper" do
      user = insert(:user)
      expected_url = "https://accounts.google.com/o/oauth2/v2/auth?client_id=test&state=encoded"

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id,
                                                                    _redirect_uri,
                                                                    opts ->
        assert Keyword.get(opts, :return_to) == "/dashboard/onboarding"
        expected_url
      end)

      assert {:ok, ^expected_url} =
               OAuth.initiate(:google, user.id, return_to: "/dashboard/onboarding")
    end
  end

  describe "initiate/3 for Outlook" do
    test "passes the user ID and the Outlook callback redirect URI to the helper" do
      user = insert(:user)

      expect(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn user_id,
                                                                     redirect_uri,
                                                                     opts ->
        assert user_id == user.id
        assert redirect_uri == "#{Endpoint.url()}/auth/outlook/calendar/callback"
        # The context starts a PKCE flow and hands the helper its challenge.
        assert [pkce: %{nonce: _nonce, code_challenge: _challenge}] = opts

        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=test"
      end)

      assert {:ok, _url} = OAuth.initiate(:outlook, user.id)
    end

    test "returns error when mock helper raises configuration error" do
      user = insert(:user)

      expect(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id,
                                                                     _redirect_uri,
                                                                     _opts ->
        raise "Client ID not configured"
      end)

      assert {:error, message} = OAuth.initiate(:outlook, user.id)
      assert String.contains?(message, "Outlook OAuth is not configured")
      assert String.contains?(message, "OUTLOOK_CLIENT_ID")
    end

    test "passes return_to option through to the helper" do
      user = insert(:user)

      expected_url =
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=test&state=encoded"

      expect(Tymeslot.OutlookOAuthHelperMock, :authorization_url, fn _user_id,
                                                                     _redirect_uri,
                                                                     opts ->
        assert Keyword.get(opts, :return_to) == "/dashboard/onboarding"
        expected_url
      end)

      assert {:ok, ^expected_url} =
               OAuth.initiate(:outlook, user.id, return_to: "/dashboard/onboarding")
    end
  end

  describe "initiate_google_scope_upgrade/2" do
    test "initiates scope upgrade using mock" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")
      expected_url = "https://accounts.google.com/upgrade"

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _user_id,
                                                                    _redirect_uri,
                                                                    _opts ->
        expected_url
      end)

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

  # The state is the only thing binding a provider's code to a Tymeslot user,
  # so it is checked against the user completing the callback before the code
  # is spent. No HTTP expectation is set: any token request fails the test.
  describe "complete/4" do
    test "refuses a state issued to another user" do
      user = insert(:user)
      state = State.generate(insert(:user).id, "test-google-state-secret")

      assert {:error, :state_user_mismatch} = OAuth.complete(:google, "code", state, user.id)
    end

    test "refuses a state signed with another provider's secret" do
      user = insert(:user)
      state = State.generate(user.id, "test-google-state-secret")

      assert {:error, "Invalid state parameter"} =
               OAuth.complete(:outlook, "code", state, user.id)
    end

    test "refuses a malformed state" do
      assert {:error, _reason} = OAuth.complete(:google, "code", "bogus", insert(:user).id)
    end
  end
end
