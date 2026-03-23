defmodule Tymeslot.Integrations.Calendar.Google.OAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :google_oauth,
      client_id: "test-id",
      client_secret: "test-secret",
      state_secret: "test-state"
    )

    :ok
  end

  describe "authorization_url/2 and /3" do
    test "returns URL from base helper" do
      url = OAuthHelper.authorization_url(1, "http://uri")
      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth"
      assert url =~ "scope=openid+email+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar"
    end

    test "handles custom scopes" do
      url = OAuthHelper.authorization_url(1, "http://uri", ["read"])
      assert url =~ "scope=openid+email+read"
    end
  end

  defp expect_token_response(access_token, refresh_token) do
    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "access_token" => access_token,
             "refresh_token" => refresh_token,
             "expires_in" => 3600,
             "scope" => "calendar"
           })
       }}
    end)
  end

  describe "handle_callback/3" do
    test "creates new integration and performs discovery" do
      user = insert(:user)
      insert(:profile, user: user)
      state = GoogleOAuthHelper.generate_state(user.id)

      expect_token_response("at-123", "rt-123")

      # Mock GoogleCalendarAPIMock.list_calendars/1
      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{id: "cal1", summary: "Primary", primary: true}]}
      end)

      assert {:ok, integration} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert integration.user_id == user.id
      assert integration.provider == "google"

      integration =
        CalendarIntegrationSchema.decrypt_credentials(integration)

      assert integration.access_token == "at-123"
    end

    test "updates existing integration" do
      user = insert(:user)
      insert(:profile, user: user)

      existing =
        insert(:calendar_integration, user: user, provider: "google", access_token: "old")

      state = GoogleOAuthHelper.generate_state(user.id)

      expect_token_response("new-at", "new-rt")

      # Expect discovery if calendar_list is empty
      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{id: "cal1", summary: "Primary", primary: true}]}
      end)

      assert {:ok, updated} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert updated.id == existing.id

      # Decrypt to check virtual fields
      updated = CalendarIntegrationSchema.decrypt_credentials(updated)
      assert updated.access_token == "new-at"
    end

    test "handles 3-tuple error from discovery without crashing" do
      user = insert(:user)
      insert(:profile, user: user)
      state = GoogleOAuthHelper.generate_state(user.id)

      expect_token_response("at-ok", "rt-ok")

      # Discovery returns a 3-tuple error (as real providers do on 401/403)
      expect(GoogleCalendarAPIMock, :list_calendars, fn _client ->
        {:error, :unauthorized, "Token expired or invalid"}
      end)

      # Should still succeed — discovery failure is non-fatal
      assert {:ok, integration} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert integration.provider == "google"
    end
  end

  describe "token operations" do
    test "exchange_code_for_tokens delegates to base helper" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "at",
               "expires_in" => 3600
             })
         }}
      end)

      assert {:ok, _result} = OAuthHelper.exchange_code_for_tokens("code", "uri")
    end

    test "refresh_access_token delegates to base helper" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _headers, _body, _opts ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "new",
               "expires_in" => 3600
             })
         }}
      end)

      assert {:ok, _result} = OAuthHelper.refresh_access_token("rt")
    end
  end
end
