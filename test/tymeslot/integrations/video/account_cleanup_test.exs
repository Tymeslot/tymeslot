defmodule Tymeslot.Integrations.Video.AccountCleanupTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :video

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Video.AccountCleanup
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  defp oauth_video(user, provider, access, refresh, name \\ "Video") do
    insert(:video_integration,
      user: user,
      name: name,
      provider: provider,
      access_token_encrypted: Encryption.encrypt(access),
      refresh_token_encrypted: Encryption.encrypt(refresh),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )
  end

  defp on_account(integration, account_id) do
    integration
    |> Changeset.change(provider_account_id: account_id)
    |> Repo.update!()
  end

  defp flip_last_byte(binary) do
    size = byte_size(binary) - 1
    <<head::binary-size(^size), last>> = binary
    head <> <<Bitwise.bxor(last, 1)>>
  end

  test "revokes a Google Meet grant with its refresh token" do
    user = insert(:user)
    oauth_video(user, "google_meet", "meet-access", "meet-refresh")

    expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
      assert url == "https://oauth2.googleapis.com/revoke"
      assert body == "token=meet-refresh"
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "revokes a Zoom grant with its access token and the app's credentials" do
    with_config(:tymeslot, :zoom_oauth,
      client_id: "zoom-id",
      client_secret: "zoom-secret",
      state_secret: "zoom-state"
    )

    stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    user = insert(:user)
    oauth_video(user, "zoom", "zoom-access", "zoom-refresh")

    expect(Tymeslot.HTTPClientMock, :post, fn url, _body, headers, _opts ->
      assert url == "https://zoom.us/oauth/revoke?token=zoom-access"
      assert {"Authorization", "Basic " <> Base.encode64("zoom-id:zoom-secret")} in headers
      {:ok, %Req.Response{status: 200, body: ~s({"status":"success"})}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "revokes the grant of a disconnected integration still awaiting room cleanup" do
    user = insert(:user)

    {:ok, _disconnected} =
      user
      |> oauth_video("google_meet", "meet-access", "disconnected-refresh")
      |> VideoIntegrationQueries.soft_delete()

    expect(Tymeslot.HTTPClientMock, :post, fn _url, body, _headers, _opts ->
      assert body == "token=disconnected-refresh"
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "revokes a disconnected Zoom grant" do
    with_config(:tymeslot, :zoom_oauth,
      client_id: "zoom-id",
      client_secret: "zoom-secret",
      state_secret: "zoom-state"
    )

    stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    user = insert(:user)

    {:ok, _disconnected} =
      user
      |> oauth_video("zoom", "disconnected-zoom-access", "zoom-refresh")
      |> VideoIntegrationQueries.soft_delete()

    expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
      assert url == "https://zoom.us/oauth/revoke?token=disconnected-zoom-access"
      {:ok, %Req.Response{status: 200, body: ~s({"status":"success"})}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  describe "an account another Tymeslot account also connected" do
    setup do
      with_config(:tymeslot, :zoom_oauth,
        client_id: "zoom-id",
        client_secret: "zoom-secret",
        state_secret: "zoom-state"
      )

      stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
        send(test_pid, {:revoke, url, body})
        {:ok, %Req.Response{status: 200, body: ~s({"status":"success"})}}
      end)

      %{user: insert(:user), other: insert(:user)}
    end

    test "keeps a Google Meet grant another account's Google Meet relies on",
         %{user: user, other: other} do
      user
      |> oauth_video("google_meet", "meet-access", "meet-refresh")
      |> on_account("google-sub-shared")

      other
      |> oauth_video("google_meet", "other-access", "other-refresh")
      |> on_account("google-sub-shared")

      assert AccountCleanup.run(user.id) == :ok

      refute_received {:revoke, _url, _body}
    end

    test "keeps a Google Meet grant another account's Google calendar relies on",
         %{user: user, other: other} do
      user
      |> oauth_video("google_meet", "meet-access", "meet-refresh")
      |> on_account("google-sub-shared")

      insert(:calendar_integration,
        user: other,
        provider: "google",
        provider_account_id: "google-sub-shared",
        refresh_token_encrypted: Encryption.encrypt("calendar-refresh")
      )

      assert AccountCleanup.run(user.id) == :ok

      refute_received {:revoke, _url, _body}
    end

    test "keeps a Zoom authorisation another account relies on", %{user: user, other: other} do
      user
      |> oauth_video("zoom", "zoom-access", "zoom-refresh")
      |> on_account("zoom-user-shared")

      other
      |> oauth_video("zoom", "other-access", "other-refresh")
      |> on_account("zoom-user-shared")

      assert AccountCleanup.run(user.id) == :ok

      refute_received {:revoke, _url, _body}
    end

    test "still revokes a Zoom authorisation on a Zoom user nobody else connected",
         %{user: user, other: other} do
      user
      |> oauth_video("zoom", "zoom-access", "zoom-refresh")
      |> on_account("zoom-user-1")

      other
      |> oauth_video("zoom", "other-access", "other-refresh")
      |> on_account("zoom-user-2")

      assert AccountCleanup.run(user.id) == :ok

      assert_received {:revoke, "https://zoom.us/oauth/revoke?token=zoom-access", _body}
    end
  end

  test "makes no call for Teams or MiroTalk" do
    user = insert(:user)
    oauth_video(user, "teams", "teams-access", "teams-refresh")
    insert(:video_integration, user: user, provider: "mirotalk")

    # DataCase stubs the client globally, so a call would pass unnoticed (and
    # a raising stub would be swallowed by the cleanup's per-integration
    # rescue). Report any call to the test process instead.
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
      send(test_pid, {:unexpected_call, url})
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
    refute_received {:unexpected_call, _url}
  end

  test "a Google Meet integration with no token is left without a revoke call or a warning" do
    user = insert(:user)

    integration =
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        access_token_encrypted: nil,
        refresh_token_encrypted: nil
      )

    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
      send(test_pid, {:unexpected_call, url})
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    LogCapture.attach(level: :warning)

    assert AccountCleanup.run(user.id) == :ok

    refute_received {:unexpected_call, _url}
    integration_id = integration.id
    refute_received {:captured_log, %{meta: %{integration_id: ^integration_id}}}
  end

  describe "best effort" do
    setup do
      with_config(:tymeslot, :zoom_oauth,
        client_id: "zoom-id",
        client_secret: "zoom-secret",
        state_secret: "zoom-state"
      )

      stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)
      LogCapture.attach(level: :warning)
      %{user: insert(:user)}
    end

    test "a failed Zoom revocation does not stop the Google Meet one", %{user: user} do
      oauth_video(user, "zoom", "zoom-access", "zoom-refresh", "A zoom")
      oauth_video(user, "google_meet", "meet-access", "meet-refresh", "B meet")

      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :post, 2, fn url, body, _headers, _opts ->
        send(test_pid, {:revoke, url, body})

        if String.starts_with?(url, "https://zoom.us/") do
          {:ok, %Req.Response{status: 500, body: ""}}
        else
          {:ok, %Req.Response{status: 200, body: ""}}
        end
      end)

      assert AccountCleanup.run(user.id) == :ok

      assert_received {:revoke, "https://oauth2.googleapis.com/revoke", "token=meet-refresh"}
      LogCapture.await_log("video grant revocation failed")
    end

    test "an integration whose credentials no longer decrypt does not stop the next one",
         %{user: user} do
      # Ciphertext the current key cannot open, as after a lost key.
      unreadable = flip_last_byte(Encryption.encrypt("meet-refresh-under-an-old-key"))
      assert Encryption.decrypt_with_status(unreadable) == {:error, :requires_reencryption}

      insert(:video_integration,
        user: user,
        name: "A unreadable",
        provider: "google_meet",
        access_token_encrypted: unreadable,
        refresh_token_encrypted: unreadable
      )

      oauth_video(user, "google_meet", "meet-access", "meet-refresh", "B meet")

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
        send(test_pid, {:revoke, url, body})
        {:ok, %Req.Response{status: 200, body: ""}}
      end)

      assert AccountCleanup.run(user.id) == :ok

      assert_received {:revoke, "https://oauth2.googleapis.com/revoke", "token=meet-refresh"}
      refute_received {:revoke, _url, _body}
      LogCapture.await_log("video grant revocation failed")
    end

    test "an integration that raises does not stop the next one", %{user: user} do
      oauth_video(user, "zoom", "zoom-access", "zoom-refresh", "A zoom")
      oauth_video(user, "google_meet", "meet-access", "meet-refresh", "B meet")

      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :post, 2, fn url, body, _headers, _opts ->
        if String.starts_with?(url, "https://zoom.us/") do
          raise "HTTP client exploded"
        else
          send(test_pid, {:revoke, url, body})
          {:ok, %Req.Response{status: 200, body: ""}}
        end
      end)

      assert AccountCleanup.run(user.id) == :ok

      assert_received {:revoke, "https://oauth2.googleapis.com/revoke", "token=meet-refresh"}
      LogCapture.await_log("video grant revocation failed")
    end
  end
end
