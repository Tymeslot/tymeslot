defmodule Tymeslot.Integrations.Calendar.Google.PushChannelTest do
  @moduledoc """
  Tests for `Tymeslot.Integrations.Calendar.Google.PushChannel.register_push_channel/1`.

  The push-channel lifecycle only fires on deployments with a configured
  webhook URL; these tests lock in the three user-observable outcomes:

    * success persists `google_channel_*` fields to the integration,
    * a missing `expiration` from Google is backfilled to a 7-day
      default so the renewal sweep can find the row,
    * missing `:webhook_base_url` is a tagged error (`:webhook_base_url_not_configured`)
      rather than a crash — the polling fallback must keep working.

  It also covers stopping a channel at Google, best-effort, once a new one
  supersedes it and when the integration is disconnected.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :integration

  import Tymeslot.Factory
  import Mox
  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Google.PushChannel
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    CalendarCircuitBreaker.reset(:google)
    on_exit(fn -> CalendarCircuitBreaker.reset(:google) end)

    prior = Application.get_env(:tymeslot, :webhook_base_url)

    on_exit(fn ->
      if prior do
        Application.put_env(:tymeslot, :webhook_base_url, prior)
      else
        Application.delete_env(:tymeslot, :webhook_base_url)
      end
    end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        default_booking_calendar_id: "primary",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

    %{integration: integration, user: user}
  end

  @stop_url "https://www.googleapis.com/calendar/v3/channels/stop"

  defp with_stored_channel(integration) do
    integration
    |> Changeset.change(
      google_channel_id: "old-channel-id",
      google_channel_resource_id: "old-resource-id",
      google_channel_expires_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    )
    |> Repo.update!()
  end

  defp watch_response do
    {:ok,
     %Req.Response{
       status: 200,
       body: Jason.encode!(%{"id" => "client-channel-id", "resourceId" => "new-resource-id"})
     }}
  end

  describe "register_push_channel/1" do
    test "returns :webhook_base_url_not_configured when the config is missing", %{
      integration: integration
    } do
      Application.delete_env(:tymeslot, :webhook_base_url)

      assert {:error, :webhook_base_url_not_configured} =
               PushChannel.register_push_channel(integration)
    end

    test "persists channel id, resource id, secret, and expiry on success", %{
      integration: integration
    } do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hooks.example.com")

      expires_ms = System.os_time(:millisecond) + 6 * 24 * 3_600_000
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url ==
                 "https://www.googleapis.com/calendar/v3/calendars/primary/events/watch"

        assert body =~ ~s("type":"web_hook")
        assert body =~ ~s("address":"https://hooks.example.com/webhooks/google-calendar")

        send(test_pid, {:watch_request, Jason.decode!(body)})

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "client-channel-id",
               "resourceId" => "server-resource-id",
               "expiration" => Integer.to_string(expires_ms)
             })
         }}
      end)

      assert {:ok, updated} = PushChannel.register_push_channel(integration)
      assert_receive {:watch_request, watch_request}

      # The persisted id and secret must be exactly the pair Google was told to
      # echo back, otherwise inbound webhook verification can never match.
      assert updated.google_channel_id == watch_request["id"]
      assert updated.google_channel_secret == watch_request["token"]
      assert updated.google_channel_resource_id == "server-resource-id"
      assert %DateTime{} = updated.google_channel_expires_at

      expected = DateTime.truncate(DateTime.from_unix!(expires_ms, :millisecond), :second)
      assert DateTime.compare(updated.google_channel_expires_at, expected) == :eq
    end

    test "backfills a 7-day expiry when Google omits the expiration field", %{
      integration: integration
    } do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hooks.example.com")

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"id" => "client-channel-id", "resourceId" => "srv-res-id"})
         }}
      end)

      before = DateTime.utc_now()

      assert {:ok, updated} = PushChannel.register_push_channel(integration)

      diff_seconds = DateTime.diff(updated.google_channel_expires_at, before, :second)
      assert diff_seconds >= 7 * 24 * 3600 - 5
      assert diff_seconds <= 7 * 24 * 3600 + 5
    end

    test "returns :circuit_open when the Google breaker is already tripped", %{
      integration: integration
    } do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hooks.example.com")

      Enum.each(1..5, fn _i ->
        CalendarCircuitBreaker.call(:google, fn -> {:provider_error, :api_failure} end)
      end)

      assert %{status: :open} = CalendarCircuitBreaker.status(:google)

      assert {:error, :circuit_open} = PushChannel.register_push_channel(integration)
    end

    test "surfaces a 401 from the watch endpoint as :unauthorized", %{integration: integration} do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hooks.example.com")

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401}}
      end)

      assert {:error, :unauthorized, _msg} = PushChannel.register_push_channel(integration)
    end
  end

  describe "replacing a stored channel" do
    setup %{integration: integration} do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hooks.example.com")
      %{integration: with_stored_channel(integration)}
    end

    test "stops the superseded channel once the new one is stored", %{integration: integration} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, 2, fn
        :post,
        "https://www.googleapis.com/calendar/v3/calendars/primary/events/watch",
        _b,
        _h,
        _o ->
          watch_response()

        :post, @stop_url, body, _headers, _opts ->
          # The stop must come after the new channel is stored, or Google
          # would push to no channel the webhook accepts in between.
          stored = Repo.get!(CalendarIntegrationSchema, integration.id)
          send(test_pid, {:stop_request, Jason.decode!(body), stored.google_channel_id})
          {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert {:ok, updated} = PushChannel.register_push_channel(integration)

      assert_receive {:stop_request, stop_body, channel_id_at_stop}
      assert stop_body == %{"id" => "old-channel-id", "resourceId" => "old-resource-id"}
      assert channel_id_at_stop == updated.google_channel_id
      refute channel_id_at_stop == "old-channel-id"
    end

    test "a failed stop leaves the new channel registered", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, 2, fn
        :post, @stop_url, _body, _headers, _opts -> {:ok, %Req.Response{status: 500, body: ""}}
        :post, _watch_url, _body, _headers, _opts -> watch_response()
      end)

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, updated} = PushChannel.register_push_channel(integration)
          assert updated.google_channel_resource_id == "new-resource-id"
        end)

      assert log =~ "Failed to stop Google Calendar push channel"

      assert Repo.get!(CalendarIntegrationSchema, integration.id).google_channel_resource_id ==
               "new-resource-id"
    end
  end

  describe "disconnecting the integration" do
    setup %{integration: integration} do
      %{integration: with_stored_channel(integration)}
    end

    test "stops its push channel", %{integration: integration, user: user} do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :post, @stop_url, body, _headers, opts ->
        send(test_pid, {:stop_request, Jason.decode!(body)})
        send(test_pid, {:stop_options, opts})
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert {:ok, _result} = Deletion.delete_with_primary_reassignment(user.id, integration.id)

      assert_receive {:stop_request,
                      %{"id" => "old-channel-id", "resourceId" => "old-resource-id"}}

      # Bounded: the disconnect click waits on this request.
      assert_receive {:stop_options, opts}
      assert opts[:request_timeout] == 5_000

      refute Repo.get(CalendarIntegrationSchema, integration.id)
    end

    test "still disconnects when the stop fails", %{integration: integration, user: user} do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, @stop_url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: ""}}
      end)

      assert {:ok, _result} = Deletion.delete_with_primary_reassignment(user.id, integration.id)
      refute Repo.get(CalendarIntegrationSchema, integration.id)
    end
  end
end
