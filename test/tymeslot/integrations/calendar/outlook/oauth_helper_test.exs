defmodule Tymeslot.Integrations.Calendar.Outlook.OAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper
  alias Tymeslot.Integrations.Common.OAuth.State
  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :outlook_oauth,
      client_id: "outlook-id",
      client_secret: "outlook-secret",
      state_secret: "outlook-state"
    )

    :ok
  end

  describe "authorization_url/2 and /3" do
    test "generates valid Outlook OAuth URL" do
      url = OAuthHelper.authorization_url(1, "http://uri")
      assert url =~ "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      assert url =~ "client_id=outlook-id"
      assert url =~ "scope=https%3A%2F%2Fgraph.microsoft.com%2FCalendars.ReadWrite"
    end

    test "accepts options for login_hint" do
      url = OAuthHelper.authorization_url(1, "http://uri", login_hint: "user@example.com")
      assert url =~ "login_hint=user%40example.com"
    end
  end

  describe "handle_callback/3" do
    test "creates new integration and performs discovery" do
      user = insert(:user)
      insert(:profile, user: user)
      state = State.generate(user.id, "outlook-state")

      expect_token_response("at-123", "rt-123")

      # Mock Outlook API for discovery
      expect(OutlookCalendarAPIMock, :list_calendars, fn _client ->
        {:ok, [%{"id" => "cal1", "name" => "Calendar", "isDefaultCalendar" => true}]}
      end)

      assert {:ok, integration} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert integration.user_id == user.id
      assert integration.provider == "outlook"

      integration =
        CalendarIntegrationSchema.decrypt_credentials(integration)

      assert integration.access_token == "at-123"
    end

    test "handles 3-tuple error from discovery without crashing" do
      user = insert(:user)
      insert(:profile, user: user)
      state = State.generate(user.id, "outlook-state")

      expect_token_response("at-ok", "rt-ok")

      # Discovery returns a 3-tuple error (as real providers do on 401/403)
      expect(OutlookCalendarAPIMock, :list_calendars, fn _client ->
        {:error, :unauthorized, "Token expired or invalid"}
      end)

      # Should still succeed — discovery failure is non-fatal
      assert {:ok, integration} = OAuthHelper.handle_callback("code", state, "http://uri")
      assert integration.provider == "outlook"
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
             "scope" => "Calendars.ReadWrite"
           })
       }}
    end)
  end

  describe "token operations" do
    test "exchange_code_for_tokens uses TokenExchange" do
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

    test "refresh_access_token uses TokenExchange" do
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
