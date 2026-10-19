defmodule Tymeslot.Integrations.Calendar.ConnectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox
  alias Tymeslot.Integrations.Calendar.Connection

  setup :verify_on_exit!

  describe "test_connection/1" do
    test "tests CalDAV provider connection" do
      integration = %{
        provider: "caldav",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      result = Connection.test_connection(integration)

      # Will fail without real server
      assert {:error, _reason} = result
    end

    # The owner learns it was the address, in their language: the reason
    # comes back from discovery as :private_address, not as a sentence.
    test "names a private server address in the owner's language" do
      user = insert(:user)

      integration = %{
        user_id: user.id,
        provider: "caldav",
        base_url: "https://10.0.0.5",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      assert {:error, message} =
               Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
                 Connection.test_connection(integration)
               end)

      assert message == "Private oder lokale Netzwerkadressen sind nicht zulässig"
    end

    test "tests Google Calendar provider connection" do
      user = insert(:user)

      integration = %{
        provider: "google",
        access_token: "test_token",
        refresh_token: "refresh_token",
        user_id: user.id
      }

      # Mock connection test
      expect(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        {:ok, []}
      end)

      result = Connection.test_connection(integration)

      assert {:ok, "Google Calendar connection successful"} = result
    end

    test "tests Nextcloud provider connection" do
      integration = %{
        provider: "nextcloud",
        base_url: "http://localhost:1",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      result = Connection.test_connection(integration)

      assert match?({:error, _reason}, result)
    end

    test "gives an interactive caller copy for refused credentials" do
      user = insert(:user)

      stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, message} = Connection.test_connection(apple_integration(user))
      assert message =~ "app-specific password"
    end

    test "gives a background probe the reason the health check classifies" do
      user = insert(:user)

      stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      # Prose reaches `ErrorAnalysis.classify_error/1` as an unfamiliar string
      # and is recorded as transient, so a scheduled probe must be handed the
      # reason itself.
      assert {:error, :unauthorized} =
               Connection.test_connection(apple_integration(user), scope: :background)
    end

    test "returns error for provider with invalid atom" do
      integration = %{
        provider: "nonexistent_provider"
      }

      result = Connection.test_connection(integration)

      assert {:error, :unsupported_provider} = result
    end

    test "returns error for unknown provider type" do
      integration = %{
        provider: "unknown"
      }

      result = Connection.test_connection(integration)

      assert {:error, :unsupported_provider} = result
    end
  end

  defp apple_integration(user) do
    %{
      provider: "apple",
      base_url: "https://caldav.icloud.com",
      username: "alice",
      password: "wrong",
      calendar_paths: [],
      user_id: user.id
    }
  end
end
