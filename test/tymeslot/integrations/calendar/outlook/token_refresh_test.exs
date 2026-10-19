defmodule Tymeslot.Integrations.Calendar.Outlook.TokenRefreshTest do
  @moduledoc """
  The live Outlook calendar token refresh, `CalendarAPI.refresh_token/1`.
  """

  # async: false: :outlook_oauth is application-wide, and LogCapture attaches a
  # global `:logger` handler.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  describe "refresh_token/1" do
    setup do
      prior = Application.get_env(:tymeslot, :outlook_oauth)
      Application.put_env(:tymeslot, :outlook_oauth, client_id: "client", client_secret: "secret")

      on_exit(fn ->
        if prior,
          do: Application.put_env(:tymeslot, :outlook_oauth, prior),
          else: Application.delete_env(:tymeslot, :outlook_oauth)
      end)

      integration =
        insert(:calendar_integration,
          user: insert(:user),
          provider: "outlook",
          refresh_token_encrypted: Encryption.encrypt("old_refresh_token")
        )

      %{integration: integration}
    end

    test "calls Microsoft token endpoint and returns new tokens", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url == "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        assert String.contains?(body, "grant_type=refresh_token")
        assert String.contains?(body, "refresh_token=old_refresh_token")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "new_access_token",
               "refresh_token" => "new_refresh_token",
               "expires_in" => 3600
             })
         }}
      end)

      assert {:ok, {"new_access_token", "new_refresh_token", %DateTime{}}} =
               CalendarAPI.refresh_token(integration)
    end

    # The body is where the OAuth error code lives; the health check can only
    # tell a revoked grant from other refusals if the code survives into the
    # message.
    test "keeps the OAuth error code from a 400 response in the message", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :post,
                                                   "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      assert {:error, :unauthorized, "Token refresh failed: invalid_grant"} =
               CalendarAPI.refresh_token(integration)
    end

    # This is the live Outlook refresh: `Calendar.Outlook.OAuthHelper` is not on
    # the path, so without the ids a refresh failure here could not be
    # attributed to an integration without joining against neighbouring lines.
    test "names the integration behind a refresh failure", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      LogCapture.attach()

      CalendarAPI.refresh_token(integration)

      meta = LogCapture.user_metadata(LogCapture.await_log("OAuth token refresh failed"))

      assert meta[:integration_id] == integration.id
      assert meta[:user_id] == integration.user_id
      assert meta[:provider] == :outlook
      assert meta[:status] == 400
    end

    # Microsoft answers a rejected client registration with a 401, not a 400.
    # Reported as a network error it would be retried eight times and the
    # owner never told.
    test "keeps the OAuth error code from a 401 response in the message", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :post,
                                                   "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok, %Req.Response{status: 401, body: ~s({"error":"invalid_client"})}}
      end)

      assert {:error, :unauthorized, "Token refresh failed: invalid_client"} =
               CalendarAPI.refresh_token(integration)
    end

    # An integration connected before its scope was recorded refreshes with
    # the scope a new connection requests, the one Teams requests too.
    test "requests the connection scope when the integration recorded none", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        assert URI.decode_query(body)["scope"] ==
                 "https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/User.Read offline_access openid profile email"

        {:ok, %Req.Response{status: 200, body: ~s({"access_token":"at"})}}
      end)

      assert {:ok, {"at", "old_refresh_token", %DateTime{}}} =
               CalendarAPI.refresh_token(%{integration | oauth_scope: nil})
    end

    # A proxy answering 200 with an HTML page used to raise `Jason.DecodeError`
    # here, inside the refresh lock. It is a transient failure, so the refresh
    # job retries it rather than asking the owner to reconnect.
    test "reports a 200 with a non-JSON body as a retryable error", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "<html>Sign in to the network</html>"}}
      end)

      assert {:error, :network_error, "HTTP 200"} = CalendarAPI.refresh_token(integration)
    end
  end
end
