defmodule Tymeslot.Integrations.VideoTest do
  use Tymeslot.DataCase, async: true

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video

  setup :verify_on_exit!

  describe "list_integrations/1" do
    test "lists all integrations for a user" do
      user = insert(:user)
      _i1 = insert(:video_integration, user: user, name: "I1")
      _i2 = insert(:video_integration, user: user, name: "I2")

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

    test "returns error for non-oauth provider" do
      assert {:error, _reason} = Video.oauth_authorization_url(1, :mirotalk)
    end
  end
end
