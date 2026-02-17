defmodule Tymeslot.Integrations.Video.ConnectionTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Integrations.Video.Connection
  import Tymeslot.Factory
  import Mox

  setup :verify_on_exit!

  describe "test_connection/2" do
    test "tests connection for mirotalk provider" do
      user = insert(:user)

      integration =
        insert(:video_integration, user: user, provider: "mirotalk", api_key: "key123")

      # MiroTalkProvider calls HTTPClient directly.
      # It might call it more than once due to HTTPS/HTTP fallback logic or multiple checks.
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      assert {:ok, "Connection successful - API key is valid"} =
               Connection.test_connection(user.id, integration.id)
    end

    test "tests connection for google_meet provider" do
      user = insert(:user)
      # Provide a token in the future to avoid refresh
      future = DateTime.add(DateTime.utc_now(), 1, :hour)

      integration =
        insert(:video_integration, user: user, provider: "google_meet", token_expires_at: future)

      # GoogleMeetProvider calls GoogleCalendarAPI which may call list_primary_events or other checks
      # It also calls HTTPClient directly for some things
      stub(GoogleCalendarAPIMock, :list_primary_events, fn _client, _start_time, _end_time ->
        {:ok, []}
      end)

      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "{\"items\": []}"}}
      end)

      assert {:ok, "Google Meet connection successful"} =
               Connection.test_connection(user.id, integration.id)
    end

    test "returns error for unauthorized user" do
      user1 = insert(:user)
      user2 = insert(:user)
      integration = insert(:video_integration, user: user1)

      # Should return :not_found because VideoIntegrationQueries.get_for_user uses both IDs
      assert {:error, :not_found} = Connection.test_connection(user2.id, integration.id)
    end

    test "handles unknown provider" do
      user = insert(:user)
      # provider "unknown" will fail String.to_existing_atom
      integration = insert(:video_integration, user: user, provider: "unknown_provider_123")

      assert {:error, :unsupported_provider} = Connection.test_connection(user.id, integration.id)
    end
  end
end
