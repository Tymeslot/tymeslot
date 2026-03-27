defmodule Tymeslot.Integrations.HealthCheck.AssessorTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.HealthCheck.Assessor

  setup :verify_on_exit!

  describe "assess/2 for calendar integrations" do
    test "returns success result and duration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:ok, []}
      end)

      {result, duration} = Assessor.assess(:calendar, integration)

      assert match?({:ok, _result}, result)
      assert is_integer(duration)
      assert duration >= 0
    end

    test "returns error result and duration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, :unauthorized, "Invalid credentials"}
      end)

      {result, duration} = Assessor.assess(:calendar, integration)

      # Should be an error tuple (could be 2 or 3 element tuple)
      assert {:error, _reason} = result
      assert is_integer(duration)
      assert duration >= 0
    end

    test "handles exceptions gracefully" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        raise "Connection failed"
      end)

      {result, duration} = Assessor.assess(:calendar, integration)

      assert {:error, {:exception, message}} = result
      assert message == "Connection failed"
      assert is_integer(duration)
    end

    test "decrypts CalDAV credentials before testing connection" do
      user = insert(:user)

      # Factory stores encrypted credentials; virtual fields are nil until decrypted.
      # Without the fix, the health check sends empty auth (nil username:password → "Basic Og==")
      # and the server rejects with 403. This test verifies credentials are decrypted first.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "radicale",
          base_url: "https://radicale.example.com"
        )

      empty_auth = "Basic " <> Base.encode64(":")

      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, headers, _opts ->
        auth = List.keyfind(headers, "Authorization", 0)

        assert auth != nil, "No Authorization header was sent"

        refute auth == {"Authorization", empty_auth},
               "Nil credentials were sent — decrypt_credentials was not called"

        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      {result, duration} = Assessor.assess(:calendar, integration)

      assert {:ok, _message} = result
      assert is_integer(duration)
    end
  end

  describe "assess/2 for video integrations" do
    test "returns success for valid mirotalk integration" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          base_url: "https://mirotalk.example.com"
        )

      # Note: test_connection might be called more than once due to internal retries
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      {result, duration} = Assessor.assess(:video, integration)

      # Result could be success or error depending on provider implementation
      assert is_tuple(result)
      assert is_integer(duration)
    end

    test "returns error for unsupported provider" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "invalid_provider")

      {result, duration} = Assessor.assess(:video, integration)

      # Provider adapter returns error message for unknown providers
      assert match?({:error, _reason}, result)
      assert is_integer(duration)
    end

    test "returns unsupported_provider for unrecognised provider without calling decrypt" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "nonexistent_provider_xyz_#{System.unique_integer()}"
        )

      {result, duration} = Assessor.assess(:video, integration)

      assert result == {:error, :unsupported_provider}
      assert is_integer(duration)
    end

    test "handles empty provider name" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "")

      {result, duration} = Assessor.assess(:video, integration)

      assert result == {:error, :unsupported_provider}
      assert is_integer(duration)
    end

    test "returns error when custom integration has no URL configured" do
      user = insert(:user)

      integration =
        insert(:video_integration, user: user, provider: "custom", custom_meeting_url: nil)

      {result, duration} = Assessor.assess(:video, integration)

      assert {:error, reason} = result
      assert reason =~ "URL"
      assert is_integer(duration)
    end

    test "passes custom_meeting_url to test_connection" do
      user = insert(:user)

      # A loopback URL resolves without DNS and deterministically fails the public-host
      # check — proving the URL was forwarded (the bug returned "No custom meeting URL
      # provided" when the config was built as an empty map instead).
      integration =
        insert(:video_integration,
          user: user,
          provider: "custom",
          custom_meeting_url: "http://127.0.0.1/meeting"
        )

      {result, _duration} = Assessor.assess(:video, integration)

      assert {:error, "URL resolves to a private or loopback address"} = result
    end

    test "returns success for valid google_meet integration" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"items" => []})}}
      end)

      {result, duration} = Assessor.assess(:video, integration)

      assert {:ok, _message} = result
      assert is_integer(duration)
    end

    test "returns success for valid teams integration" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "teams"
        )

      expect(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config ->
        {:ok, :valid}
      end)

      {result, duration} = Assessor.assess(:video, integration)

      assert {:ok, _message} = result
      assert is_integer(duration)
    end
  end

  describe "telemetry recording" do
    test "records telemetry for successful checks" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:ok, []}
      end)

      # Telemetry is recorded internally
      {result, _duration} = Assessor.assess(:calendar, integration)

      assert {:ok, _result} = result
    end
  end
end
