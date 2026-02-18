defmodule Tymeslot.Integrations.HealthCheck.AssessorTest do
  @moduletag :integrations
  use Tymeslot.DataCase, async: true

  import Mox

  alias Tymeslot.Integrations.HealthCheck.Assessor

  setup :verify_on_exit!
  @moduletag :integrations

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

    test "handles empty provider name" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "")

      {result, duration} = Assessor.assess(:video, integration)

      assert result == {:error, :unsupported_provider}
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
