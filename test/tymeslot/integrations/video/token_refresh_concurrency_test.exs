defmodule Tymeslot.Integrations.Video.TokenRefreshConcurrencyTest do
  @moduletag :integrations
  @moduledoc """
  @moduletag :integrations
  Concurrency tests for video provider OAuth token refresh operations.

  ## Note on Process.sleep Usage

  This test file intentionally uses `Process.sleep/1` in mocks to simulate
  slow external OAuth refresh calls and verify that the locking mechanism
  prevents duplicate token refreshes when multiple requests arrive concurrently.

  The sleeps create a realistic timing window where multiple requests can
  overlap, allowing us to verify that only ONE refresh actually occurs.
  """

  # async: false because we use set_mox_global()
  use Tymeslot.DataCase, async: false

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.Rooms

  setup :verify_on_exit!

  setup do
    set_mox_global()
    :ok
  end

  describe "token refresh concurrency" do
    test "Google Meet token refresh is only called once even with multiple concurrent requests" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Google Meet Concurrent",
          provider: "google_meet",
          access_token: "expired",
          refresh_token: "refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
        })

      # CRITICAL: We expect exactly ONE call to refresh_access_token
      expect(Tymeslot.GoogleOAuthHelperMock, :refresh_access_token, 1, fn _token, _scope ->
        # Intentional sleep: Simulate slow OAuth provider response to create
        # a timing window where concurrent requests can overlap, testing that
        # the locking mechanism prevents duplicate refreshes
        Process.sleep(100)

        {:ok,
         %{
           access_token: "newly_refreshed_token",
           refresh_token: "refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600),
           scope: "scope"
         }}
      end)

      # Also mock the HTTP client for the actual meeting creation
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "conferenceData" => %{
                 "entryPoints" => [
                   %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
                 ]
               }
             })
         }}
      end)

      # Start 10 concurrent requests
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Rooms.create_meeting_room(user.id, integration_id: integration.id)
          end)
        end

      # Wait for all to finish
      results = Task.await_many(tasks, 5000)

      # All should have succeeded
      for result <- results do
        assert {:ok, room} = result
        assert room.provider_type == :google_meet
      end
    end

    test "Teams token refresh is only called once even with multiple concurrent requests" do
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Teams Concurrent",
          provider: "teams",
          access_token: "expired",
          refresh_token: "refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600),
          # Teams provider needs these in config
          tenant_id: "tenant",
          client_id: "client",
          client_secret: "secret",
          teams_user_id: "user",
          oauth_scope: "Calendars.ReadWrite"
        })

      # Mock validation - called by each process
      stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config ->
        {:ok, :needs_refresh}
      end)

      # CRITICAL: We expect exactly ONE call to refresh_access_token
      expect(Tymeslot.TeamsOAuthHelperMock, :refresh_access_token, 1, fn _token, _scope ->
        Process.sleep(100)

        {:ok,
         %{
           access_token: "newly_refreshed_teams_token",
           refresh_token: "refresh",
           expires_at: DateTime.add(DateTime.utc_now(), 3600),
           scope: "scope"
         }}
      end)

      # Mock Teams API call
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "teams-123",
               "onlineMeetingUrl" => "https://teams.microsoft.com/l/meetup-join/123",
               "joinWebUrl" => "https://teams.microsoft.com/l/meetup-join/123",
               "videoTeleconferenceId" => "vid-123",
               "passcode" => "123456"
             })
         }}
      end)

      # Start 10 concurrent requests
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Rooms.create_meeting_room(user.id, integration_id: integration.id)
          end)
        end

      # Wait for all to finish
      results = Task.await_many(tasks, 5000)

      # All should have succeeded
      for result <- results do
        assert {:ok, room} = result
        assert room.provider_type == :teams
      end
    end
  end
end
