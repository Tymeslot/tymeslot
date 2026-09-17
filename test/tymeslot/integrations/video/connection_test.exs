defmodule Tymeslot.Integrations.Video.ConnectionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Security.Encryption
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

      assert {:ok, "Google Meet connected successfully!"} =
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

  describe "test_integration/2 for a Talk account that may not create conversations" do
    setup do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "nextcloud_talk",
          base_url: "https://restricted.connection.example.com",
          client_id_encrypted: Encryption.encrypt("organiser"),
          client_secret_encrypted: Encryption.encrypt("App-Password"),
          provider_account_id: "https://restricted.connection.example.com||organiser"
        )

      # Two requests: who is signed in, then what the server says about them.
      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        data =
          if String.ends_with?(url, "/ocs/v2.php/cloud/user") do
            %{"id" => "organiser"}
          else
            %{
              "capabilities" => %{
                "spreed" => %{
                  "version" => "25.0.0",
                  "features" => ["conversation-creation-all"],
                  "config" => %{"conversations" => %{"can-create" => false}}
                }
              }
            }
          end

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"ocs" => %{"data" => data}})}}
      end)

      %{integration: integration}
    end

    test "a test the owner asked for reports it", %{integration: integration} do
      assert {:error, {:not_permitted, message}} = Connection.test_integration(integration)
      assert message =~ "create conversations"
    end

    # A server setting is not a broken connection: counting it against the
    # integration's health would end in an unhealthy email and a pause.
    test "the background health check passes it", %{integration: integration} do
      assert {:ok, _message} = Connection.test_integration(integration, scope: :background)
    end
  end

  describe "test_integration/2 for a Talk account whose server now allows conversations" do
    setup do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "nextcloud_talk",
          base_url: "https://allowed.connection.example.com",
          client_id_encrypted: Encryption.encrypt("organiser"),
          client_secret_encrypted: Encryption.encrypt("App-Password"),
          provider_account_id: "https://allowed.connection.example.com||organiser",
          room_creation_error: :password_required,
          room_creation_error_since: DateTime.utc_now(:second)
        )

      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        data =
          if String.ends_with?(url, "/ocs/v2.php/cloud/user") do
            %{"id" => "organiser"}
          else
            %{
              "capabilities" => %{
                "spreed" => %{
                  "version" => "25.0.0",
                  "features" => ["conversation-creation-all"],
                  "config" => %{
                    "conversations" => %{"can-create" => true, "force-passwords" => false}
                  }
                }
              }
            }
          end

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"ocs" => %{"data" => data}})}}
      end)

      %{integration: integration}
    end

    # The owner fixed the setting and pressed Test connection: the notice on
    # their integration's row has just been disproved.
    test "a passing test the owner asked for clears the recorded refusal", %{
      integration: integration
    } do
      assert {:ok, _message} = Connection.test_integration(integration)

      assert %{room_creation_error: nil, room_creation_error_since: nil} =
               Repo.reload!(integration)
    end

    test "the background health check leaves the recorded refusal alone", %{
      integration: integration
    } do
      assert {:ok, _message} = Connection.test_integration(integration, scope: :background)
      assert Repo.reload!(integration).room_creation_error == :password_required
    end
  end
end
