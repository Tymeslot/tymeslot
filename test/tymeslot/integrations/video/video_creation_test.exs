defmodule Tymeslot.Integrations.Video.VideoCreationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  @app_id "tymeslot"
  @secret String.duplicate("s", 32)
  @short_secret String.duplicate("s", 31)

  setup do
    %{user: insert(:user)}
  end

  describe "create_integration/3 for kmeet" do
    test "creates without any URL input", %{user: user} do
      assert {:ok, integration} =
               Video.create_integration(user.id, :kmeet, %{name: "My kMeet"})

      assert integration.provider == "kmeet"
      assert is_nil(integration.provider_account_id)
    end

    test "refuses a second active kMeet integration for the same user", %{user: user} do
      assert {:ok, _first} = Video.create_integration(user.id, :kmeet, %{name: "My kMeet"})

      assert {:error, changeset} =
               Video.create_integration(user.id, :kmeet, %{name: "Another kMeet"})

      assert "an integration for this provider already exists" in errors_on(changeset).user_id
    end
  end

  describe "create_integration/3 for jitsi" do
    test "stores the server URL as the dedup key", %{user: user} do
      assert {:ok, integration} =
               Video.create_integration(user.id, :jitsi, %{
                 name: "Our Jitsi",
                 base_url: "https://meet.example.com"
               })

      assert integration.provider == "jitsi"
      assert integration.provider_account_id == "https://meet.example.com"
    end

    test "stores a complete credential pair", %{user: user} do
      assert {:ok, integration} = create_jitsi(user, client_id: @app_id, client_secret: @secret)

      assert {:ok, stored} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
      assert stored.client_id == @app_id
      assert stored.client_secret == @secret
    end

    test "allows two Jitsi integrations on different servers", %{user: user} do
      assert {:ok, _a} =
               Video.create_integration(user.id, :jitsi, %{
                 name: "A",
                 base_url: "https://a.example.com"
               })

      assert {:ok, _b} =
               Video.create_integration(user.id, :jitsi, %{
                 name: "B",
                 base_url: "https://b.example.com"
               })
    end

    test "refuses a duplicate server", %{user: user} do
      assert {:ok, _a} =
               Video.create_integration(user.id, :jitsi, %{
                 name: "A",
                 base_url: "https://a.example.com"
               })

      assert {:error, :duplicate_integration} =
               Video.create_integration(user.id, :jitsi, %{
                 name: "A again",
                 base_url: "https://a.example.com"
               })
    end

    test "refuses a secret shorter than 32 bytes and saves nothing", %{user: user} do
      assert {:error, message} =
               create_jitsi(user, client_id: @app_id, client_secret: @short_secret)

      assert message =~ "at least 32 bytes"
      assert Video.list_integrations(user.id) == []
    end

    test "refuses an App ID without its secret and saves nothing", %{user: user} do
      assert {:error, message} = create_jitsi(user, client_id: @app_id)

      assert message =~ "Enter the App secret"
      assert Video.list_integrations(user.id) == []
    end

    test "refuses a server URL carrying a query string", %{user: user} do
      assert {:error, message} =
               Video.create_integration(user.id, :jitsi, %{
                 name: "Our Jitsi",
                 base_url: "https://meet.example.com/?room=x"
               })

      assert message =~ "cannot contain a query string"
      assert Video.list_integrations(user.id) == []
    end
  end

  describe "update_integration/3 for jitsi" do
    setup %{user: user} do
      {:ok, integration} = create_jitsi(user, client_id: @app_id, client_secret: @secret)
      %{integration: integration}
    end

    test "refuses a secret shorter than 32 bytes and keeps the stored one", %{
      user: user,
      integration: integration
    } do
      assert {:error, message} =
               Video.update_integration(user.id, integration.id, %{client_secret: @short_secret})

      assert message =~ "at least 32 bytes"
      assert stored_secret(user, integration) == @secret
    end

    # `cast/3` trims a whitespace-only value to nil, so the stored credential
    # is never overwritten and validation must not treat it as half a pair.
    test "a whitespace App ID keeps the stored one", %{user: user, integration: integration} do
      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, %{client_id: "   "})

      assert {:ok, stored} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
      assert stored.client_id == @app_id
      assert stored.client_secret == @secret
    end

    test "refuses a server URL carrying a query string and keeps the stored one", %{
      user: user,
      integration: integration
    } do
      assert {:error, message} =
               Video.update_integration(user.id, integration.id, %{
                 base_url: "https://meet.example.com/?room=x"
               })

      assert message =~ "cannot contain a query string"

      assert {:ok, stored} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
      assert stored.base_url == "https://meet.example.com"
    end

    test "accepts a new valid secret", %{user: user, integration: integration} do
      new_secret = String.duplicate("n", 40)

      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, %{client_secret: new_secret})

      assert stored_secret(user, integration) == new_secret
    end

    # A blank secret leaves the stored one in place, so the new App ID pairs
    # with it rather than being refused as half a pair.
    test "validates a new App ID against the stored secret when the secret is left blank", %{
      user: user,
      integration: integration
    } do
      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, %{
                 client_id: "other-app",
                 client_secret: ""
               })

      assert {:ok, stored} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
      assert stored.client_id == "other-app"
      assert stored.client_secret == @secret
    end

    test "renames without being refused over the config it leaves alone", %{
      user: user,
      integration: integration
    } do
      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{name: "Renamed"})

      assert updated.name == "Renamed"
    end
  end

  describe "update_integration/3 with string keys" do
    test "renames a MiroTalk integration", %{user: user} do
      integration = insert(:video_integration, user: user, provider: "mirotalk", name: "Before")

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{"name" => "After"})

      assert updated.name == "After"
    end
  end

  defp create_jitsi(user, credentials) do
    attrs =
      Map.merge(%{name: "Our Jitsi", base_url: "https://meet.example.com"}, Map.new(credentials))

    Video.create_integration(user.id, :jitsi, attrs)
  end

  defp stored_secret(user, integration) do
    {:ok, stored} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
    stored.client_secret
  end
end
