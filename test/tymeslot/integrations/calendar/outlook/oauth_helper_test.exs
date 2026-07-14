defmodule Tymeslot.Integrations.Calendar.Outlook.OAuthHelperTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
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

      # The initial delta baseline is seeded by the worker, not inline: the
      # integration lands with a nil `graph_delta_link` and the enqueued job
      # bootstraps it (and registers the Graph subscription) on its first run.
      assert is_nil(integration.graph_delta_link)

      assert_enqueued(
        worker: RefreshOutlookCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )

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

  # The token exchange is the only HTTP call `handle_callback/3` makes — calendar
  # discovery goes through `OutlookCalendarAPIMock`, and the initial delta fetch
  # is the enqueued worker's job, not the callback's.
  defp expect_token_response(access_token, refresh_token) do
    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
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

    test "refresh_access_token surfaces OAuth error type on 400 with invalid_client body" do
      resp_body = Jason.encode!(%{"error" => "invalid_client"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 400, body: resp_body}}
      end)

      assert {:error, msg} = OAuthHelper.refresh_access_token("bad-rt")
      assert msg == "Token refresh failed: invalid_client"
    end

    test "refresh_access_token returns generic message for 5xx responses" do
      resp_body = Jason.encode!(%{"error" => "access_denied"})

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %{status: 503, body: resp_body}}
      end)

      assert {:error, msg} = OAuthHelper.refresh_access_token("rt")
      assert msg == "Token refresh failed: HTTP 503 (see logs for details)"
      refute msg =~ "access_denied"
    end
  end
end
