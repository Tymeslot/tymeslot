defmodule Tymeslot.Integrations.Common.OAuth.RefreshLogContextTest do
  # async: false: LogCapture attaches a global `:logger` handler, and the OAuth
  # client configuration these helpers read is application-wide.
  use ExUnit.Case, async: false

  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper, as: OutlookOAuthHelper
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Shared.OAuth.TokenFlow
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  @context [integration_id: 42, user_id: 7]

  setup do
    put_oauth_env(:google_oauth,
      client_id: "google-id",
      client_secret: "google-secret",
      state_secret: "google-state"
    )

    put_oauth_env(:outlook_oauth,
      client_id: "microsoft-id",
      client_secret: "microsoft-secret",
      state_secret: "microsoft-state"
    )

    put_oauth_env(:zoom_oauth,
      client_id: "zoom-id",
      client_secret: "zoom-secret",
      state_secret: "zoom-state"
    )

    :ok
  end

  # Each helper is pinned by a behaviour that fixed its arity at two, which is
  # why the ids the caller held never reached the line. One case per helper, so
  # a helper widened without its call site being threaded through shows up here
  # rather than in production during an incident.
  describe "refresh failures name the integration" do
    test "Teams" do
      expect_refresh_rejection()
      LogCapture.attach()

      TeamsOAuthHelper.refresh_access_token("rt", nil, log_context: @context)

      assert_named(:teams)
    end

    test "Zoom" do
      expect_refresh_rejection()
      LogCapture.attach()

      ZoomOAuthHelper.refresh_access_token("rt", nil, log_context: @context)

      assert_named(:zoom)
    end

    # The Google Meet video path and the Google Calendar path both log
    # `provider: :google`, so the integration id is the only thing that tells
    # one of their failures from the other.
    test "Google (the shared helper behind Google Meet)" do
      expect_refresh_rejection()
      LogCapture.attach()

      GoogleOAuthHelper.refresh_access_token("rt", nil, log_context: @context)

      assert_named(:google)
    end

    test "Outlook" do
      expect_refresh_rejection()
      LogCapture.attach()

      OutlookOAuthHelper.refresh_access_token("rt", nil, log_context: @context)

      assert_named(:outlook)
    end

    # TokenFlow is the live Outlook calendar refresh, and used to log nothing
    # at all on failure.
    test "TokenFlow" do
      expect_refresh_rejection()
      LogCapture.attach()

      TokenFlow.refresh_token("http://oauth", %{refresh_token: "rt"},
        log_context: @context ++ [provider: :outlook]
      )

      assert_named(:outlook)
    end
  end

  describe "the allowed-key filter" do
    # Every caller on these paths is holding decrypted OAuth credentials when
    # it logs, so a key nobody vetted must not reach the line however it is
    # spelled.
    test "TokenFlow drops keys outside the allowed set" do
      expect_refresh_rejection()
      LogCapture.attach()

      TokenFlow.refresh_token("http://oauth", %{refresh_token: "rt"},
        log_context: [
          integration_id: 42,
          access_token: "secret-access",
          refresh_token: "secret-refresh",
          client_secret: "secret-client",
          user_id: nil
        ]
      )

      event = LogCapture.await_log("OAuth token refresh failed")
      meta = LogCapture.user_metadata(event)

      assert meta[:integration_id] == 42
      refute Map.has_key?(meta, :access_token)
      refute Map.has_key?(meta, :refresh_token)
      refute Map.has_key?(meta, :client_secret)
      refute Map.has_key?(meta, :user_id)

      dump = LogCapture.dump(event)
      refute dump =~ "secret-access"
      refute dump =~ "secret-refresh"
      refute dump =~ "secret-client"
    end

    # A helper pins its own provider, so a caller cannot relabel a Zoom failure
    # as something else.
    test "a helper's own provider wins over a caller-supplied one" do
      expect_refresh_rejection()
      LogCapture.attach()

      ZoomOAuthHelper.refresh_access_token("rt", nil,
        log_context: [integration_id: 42, provider: :not_zoom]
      )

      assert LogCapture.user_metadata(LogCapture.await_log("OAuth token refresh failed"))[
               :provider
             ] == :zoom
    end

    test "TokenFlow redacts the response body of a failed exchange" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 400,
           body: ~s({"access_token":"leaked-123","error":"invalid_request"})
         }}
      end)

      LogCapture.attach()

      TokenFlow.exchange_code("http://oauth", %{code: "c"}, log_context: [provider: :google])

      event = LogCapture.await_log("OAuth token exchange failed")

      assert LogCapture.user_metadata(event)[:provider] == :google
      refute LogCapture.dump(event) =~ "leaked-123"
    end
  end

  defp expect_refresh_rejection do
    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
    end)
  end

  defp assert_named(provider) do
    meta = LogCapture.user_metadata(LogCapture.await_log("OAuth token refresh failed"))

    assert meta[:integration_id] == 42
    assert meta[:user_id] == 7
    assert meta[:provider] == provider
    assert meta[:status] == 400
  end

  defp put_oauth_env(key, value) do
    prior = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, value)

    on_exit(fn ->
      if prior do
        Application.put_env(:tymeslot, key, prior)
      else
        Application.delete_env(:tymeslot, key)
      end
    end)
  end
end
