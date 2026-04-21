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
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :integration

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
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

    %{integration: integration}
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

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url ==
                 "https://www.googleapis.com/calendar/v3/calendars/primary/events/watch"

        assert body =~ ~s("type":"web_hook")
        assert body =~ ~s("address":"https://hooks.example.com/webhooks/google-calendar")

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

      assert is_binary(updated.google_channel_id)
      assert updated.google_channel_resource_id == "server-resource-id"
      assert is_binary(updated.google_channel_secret)
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
        CalendarCircuitBreaker.call(:google, fn -> {:error, :api_failure} end)
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
end
