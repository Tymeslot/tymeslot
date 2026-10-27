defmodule Tymeslot.Integrations.Calendar.AccountCleanupTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.AccountCleanup
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  defp oauth_calendar(user, attrs) do
    insert(
      :calendar_integration,
      Map.merge(
        %{
          user: user,
          access_token_encrypted: Encryption.encrypt("calendar-access"),
          refresh_token_encrypted: Encryption.encrypt("calendar-refresh"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        attrs
      )
    )
  end

  test "stops the Google push channel, then revokes the Google grant" do
    user = insert(:user)

    oauth_calendar(user, %{
      provider: "google",
      google_channel_id: "chan-1",
      google_channel_resource_id: "res-1"
    })

    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, headers, _opts ->
      send(test_pid, {:stop, url, Jason.decode!(body), headers})
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
      send(test_pid, {:revoke, url, body})
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok

    # Order matters: once the grant is revoked the channel can no longer be
    # stopped, so the stop has to arrive first.
    {:messages, messages} = Process.info(self(), :messages)
    assert Enum.map(messages, &elem(&1, 0)) == [:stop, :revoke]

    assert_received {:stop, "https://www.googleapis.com/calendar/v3/channels/stop",
                     %{"id" => "chan-1", "resourceId" => "res-1"}, headers}

    assert {"Authorization", "Bearer calendar-access"} in headers
    assert_received {:revoke, "https://oauth2.googleapis.com/revoke", "token=calendar-refresh"}
  end

  describe "a Google account another Tymeslot account also connected" do
    setup do
      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :request, fn :post, url, _body, _headers, _opts ->
        send(test_pid, {:stop, url})
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      stub(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
        send(test_pid, {:revoke, url, body})
        {:ok, %Req.Response{status: 200, body: ""}}
      end)

      user = insert(:user)

      oauth_calendar(user, %{
        provider: "google",
        provider_account_id: "google-sub-shared",
        google_channel_id: "chan-1",
        google_channel_resource_id: "res-1"
      })

      %{user: user, other: insert(:user)}
    end

    test "through its calendar keeps the grant, while the channel is still stopped",
         %{user: user, other: other} do
      oauth_calendar(other, %{provider: "google", provider_account_id: "google-sub-shared"})

      assert AccountCleanup.run(user.id) == :ok

      assert_received {:stop, "https://www.googleapis.com/calendar/v3/channels/stop"}
      refute_received {:revoke, _url, _body}
    end

    test "through its Google Meet keeps the grant", %{user: user, other: other} do
      insert(:video_integration,
        user: other,
        provider: "google_meet",
        provider_account_id: "google-sub-shared"
      )

      assert AccountCleanup.run(user.id) == :ok

      refute_received {:revoke, _url, _body}
    end

    test "on a different Google account does not stop the revoke", %{user: user, other: other} do
      oauth_calendar(other, %{provider: "google", provider_account_id: "google-sub-other"})

      assert AccountCleanup.run(user.id) == :ok

      assert_received {:revoke, "https://oauth2.googleapis.com/revoke", "token=calendar-refresh"}
    end
  end

  test "a channel Google no longer has counts as stopped, without a warning" do
    user = insert(:user)

    oauth_calendar(user, %{
      provider: "google",
      google_channel_id: "chan-1",
      google_channel_resource_id: "res-1"
    })

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 404, body: ""}}
    end)

    expect(Tymeslot.HTTPClientMock, :post, fn "https://oauth2.googleapis.com/revoke",
                                              _b,
                                              _h,
                                              _o ->
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    LogCapture.attach(level: :warning)

    assert AccountCleanup.run(user.id) == :ok

    refute_received {:captured_log, %{meta: %{step: :stop_push_channel}}}
  end

  test "an integration that cannot be cleaned up does not stop the next one" do
    user = insert(:user)

    # Lists first (same activity, name sorts first), and cannot be decrypted.
    oauth_calendar(user, %{
      name: "A broken",
      provider: "google",
      access_token_encrypted: :crypto.strong_rand_bytes(64)
    })

    healthy =
      oauth_calendar(user, %{
        name: "B healthy",
        provider: "outlook",
        graph_subscription_id: "sub-1"
      })

    expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert url == "https://graph.microsoft.com/v1.0/subscriptions/sub-1"
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    LogCapture.attach(level: :warning)

    assert AccountCleanup.run(user.id) == :ok

    broken_log = LogCapture.await_log("calendar cleanup step failed")
    assert %{step: :clean_up, integration_id: id} = LogCapture.user_metadata(broken_log)
    refute id == healthy.id
  end

  test "revokes the grant even when stopping the channel fails" do
    user = insert(:user)

    oauth_calendar(user, %{
      provider: "google",
      google_channel_id: "chan-1",
      google_channel_resource_id: "res-1"
    })

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 500, body: ""}}
    end)

    expect(Tymeslot.HTTPClientMock, :post, fn "https://oauth2.googleapis.com/revoke",
                                              _b,
                                              _h,
                                              _o ->
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "deletes the Microsoft Graph subscription of an Outlook calendar" do
    user = insert(:user)
    oauth_calendar(user, %{provider: "outlook", graph_subscription_id: "sub-1"})

    expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, headers, _opts ->
      assert url == "https://graph.microsoft.com/v1.0/subscriptions/sub-1"
      assert {"Authorization", "Bearer calendar-access"} in headers
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "a Google calendar with no token is left without a revoke call or a warning" do
    user = insert(:user)

    oauth_calendar(user, %{
      provider: "google",
      access_token_encrypted: nil,
      refresh_token_encrypted: nil
    })

    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
      send(test_pid, {:unexpected_call, url})
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    LogCapture.attach(level: :warning)

    assert AccountCleanup.run(user.id) == :ok

    refute_received {:unexpected_call, _url}
    refute_received {:captured_log, %{meta: %{step: :revoke_grant}}}
  end

  test "makes no call for a CalDAV calendar" do
    user = insert(:user)
    insert(:calendar_integration, user: user, provider: "caldav")

    assert AccountCleanup.run(user.id) == :ok
  end
end
