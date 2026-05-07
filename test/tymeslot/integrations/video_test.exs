defmodule Tymeslot.Integrations.VideoTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Repo
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup :verify_on_exit!

  describe "list_integrations/1" do
    test "lists all integrations for a user" do
      user = insert(:user)
      _i1 = insert(:video_integration, user: user, name: "I1", provider: "mirotalk")
      _i2 = insert(:video_integration, user: user, name: "I2", provider: "custom")

      integrations = Video.list_integrations(user.id)
      assert length(integrations) == 2
    end
  end

  describe "create_integration/3" do
    test "creates mirotalk integration after testing connection" do
      user = insert(:user)

      attrs = %{
        "name" => "My MiroTalk",
        "base_url" => "https://mirotalk.test",
        "api_key" => "test-key"
      }

      # Mock connection test - called twice
      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      assert {:ok, integration} = Video.create_integration(user.id, :mirotalk, attrs)
      assert integration.provider == "mirotalk"
      assert integration.name == "My MiroTalk"
    end

    test "returns error if mirotalk connection test fails" do
      user = insert(:user)

      attrs = %{
        "name" => "Bad MiroTalk",
        "base_url" => "https://mirotalk.test",
        "api_key" => "bad-key"
      }

      # Mock connection failure
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: "Unauthorized"}}
      end)

      assert {:error, "Invalid API key - Authentication failed"} =
               Video.create_integration(user.id, :mirotalk, attrs)
    end

    test "safely handles non-existing atom keys in attrs" do
      user = insert(:user)

      attrs = %{
        "name" => "Safe Integration",
        "custom_meeting_url" => "https://meet.jit.si/my-room",
        "some_crazy_key_that_does_not_exist_as_atom_12345" => "value"
      }

      # Should not crash and successfully create integration (ignoring the bad key)
      assert {:ok, integration} = Video.create_integration(user.id, :custom, attrs)
      assert integration.name == "Safe Integration"
    end
  end

  describe "delete_integration/2" do
    test "deletes user's integration" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      assert {:ok, :deleted} = Video.delete_integration(user.id, integration.id)
      assert Video.list_integrations(user.id) == []
    end
  end

  describe "toggle_integration/2" do
    test "toggles active status" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      {:ok, updated} = Video.toggle_integration(user.id, integration.id)
      refute updated.is_active

      {:ok, updated2} = Video.toggle_integration(user.id, integration.id)
      assert updated2.is_active
    end

    test "enqueues an IntegrationHealthWorker probe when reactivating (inactive → active)" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: false)

      assert {:ok, updated} = Video.toggle_integration(user.id, integration.id)
      assert updated.is_active

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when deactivating (active → inactive)" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      assert {:ok, updated} = Video.toggle_integration(user.id, integration.id)
      refute updated.is_active

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end
  end

  describe "update_integration/3" do
    test "returns the updated integration on success" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, name: "Old Name")

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{name: "New Name"})

      assert updated.name == "New Name"
    end

    test "enqueues an IntegrationHealthWorker probe and resets the health row when credential fields are present" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      # Seed an unhealthy row so we can verify the reset fires.
      %IntegrationHealthStateSchema{}
      |> IntegrationHealthStateSchema.changeset(%{
        integration_type: "video",
        integration_id: integration.id,
        user_id: user.id,
        status: "unhealthy",
        failures: 5,
        consecutive_hard_failures: 5,
        successes: 0,
        backoff_ms: :timer.hours(1)
      })
      |> Repo.insert!()

      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, %{
                 api_key_encrypted: "new-encrypted-key"
               })

      # Health row is reset to a healthy baseline.
      {:ok, row} = IntegrationHealthStateQueries.get(:video, integration.id)
      assert row.status == "healthy"
      assert row.failures == 0

      # Immediate verification probe is enqueued.
      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end

    test "does NOT enqueue a probe when no credential fields are present" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, name: "Before")

      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, %{name: "After"})

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => integration.id}
      )
    end

    test "returns {:error, :not_found} for an integration belonging to another user" do
      user = insert(:user)
      other = insert(:user)
      integration = insert(:video_integration, user: other)

      assert {:error, :not_found} =
               Video.update_integration(user.id, integration.id, %{name: "Stolen"})
    end
  end

  describe "oauth_authorization_url/2" do
    test "generates google meet auth URL" do
      user = insert(:user)

      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _uid, _uri, _scopes ->
        "https://accounts.google.com/o/oauth2/v2/auth?client_id=123"
      end)

      assert {:ok, url} = Video.oauth_authorization_url(user.id, :google_meet)
      assert String.contains?(url, "accounts.google.com")
    end

    test "generates teams auth URL" do
      user = insert(:user)

      expect(Tymeslot.TeamsOAuthHelperMock, :authorization_url, fn _uid, _uri ->
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=456"
      end)

      assert {:ok, url} = Video.oauth_authorization_url(user.id, :teams)
      assert String.contains?(url, "login.microsoftonline.com")
    end

    test "generates zoom auth URL" do
      user = insert(:user)

      expect(Tymeslot.ZoomOAuthHelperMock, :authorization_url, fn _uid, _uri ->
        "https://zoom.us/oauth/authorize?client_id=test-client-id&response_type=code"
      end)

      assert {:ok, url} = Video.oauth_authorization_url(user.id, :zoom)
      assert String.contains?(url, "zoom.us")
    end

    test "returns error when zoom oauth helper raises" do
      user = insert(:user)

      expect(Tymeslot.ZoomOAuthHelperMock, :authorization_url, fn _uid, _uri ->
        raise RuntimeError, "Zoom Client ID not configured"
      end)

      assert {:error, message} = Video.oauth_authorization_url(user.id, :zoom)
      assert is_binary(message)
      assert String.contains?(message, "Zoom")
    end

    test "returns error for non-oauth provider" do
      assert {:error, _reason} = Video.oauth_authorization_url(1, :mirotalk)
    end
  end
end
