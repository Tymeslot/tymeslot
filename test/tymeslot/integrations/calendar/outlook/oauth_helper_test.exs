defmodule Tymeslot.Integrations.Calendar.Outlook.OAuthHelperTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
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

  # Dispatches on the HTTP verb in a single multi-clause stub:
  #
  #   * `:post` → succeeds with a token payload (the token exchange)
  #   * anything else → `Mint.TransportError{reason: :timeout}` (the
  #     supervised seed_delta_async task's `:get` against Graph)
  #
  # Using `stub/3` rather than `expect/4` is deliberate. In `async: false`
  # Mox shared mode, a supervised task from a *previous* test can still be
  # running when this test's setup installs its mocks. That stray task
  # makes the next HTTPClient.request call the test sees. If we used an
  # `expect`, the stray task would consume it — with the wrong HTTP verb
  # — so when the real token exchange fires, its call would fall through
  # to the fallback stub and return `:timeout`, manifesting as
  # `{:error, "Network error during token exchange: ..."}` from the
  # `handle_callback/3` flow. A single multi-clause stub matches on verb,
  # is not consumed, and is therefore immune to the cross-test race.
  defp expect_token_response(access_token, refresh_token) do
    stub(Tymeslot.HTTPClientMock, :request, fn
      :post, _url, _body, _headers, _opts ->
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

      _other_method, _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
    end)
  end

  describe "token operations" do
    test "exchange_code_for_tokens uses TokenExchange" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
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
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
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
