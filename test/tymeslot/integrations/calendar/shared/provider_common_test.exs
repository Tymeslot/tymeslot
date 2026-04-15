defmodule Tymeslot.Integrations.Calendar.Shared.ProviderCommonTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon

  setup :verify_on_exit!

  describe "test_caldav_provider_connection/2" do
    test "uses provider-specific discovery URL when integration.provider is a string" do
      # Regression: a string provider (as stored in the DB) was falling through
      # to the generic `/calendars/<user>/` path instead of the radicale-specific
      # `/<user>/` path, causing health checks to hit a URL Radicale 403s on.
      test_pid = self()

      Mox.expect(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, _headers, _opts ->
        send(test_pid, {:propfind_url, url})
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      integration = %{
        base_url: "https://radicale.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: "radicale"
      }

      assert {:ok, "Radicale OK"} =
               ProviderCommon.test_caldav_provider_connection(integration,
                 success_message: "Radicale OK",
                 unauthorized_message: "unauth",
                 not_found_message: "not found",
                 error_formatter: &inspect/1
               )

      assert_received {:propfind_url, "https://radicale.example.com/alice/"}
    end

    test "accepts atom providers as well" do
      test_pid = self()

      Mox.expect(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, _headers, _opts ->
        send(test_pid, {:propfind_url, url})
        {:ok, %Req.Response{status: 207, body: ""}}
      end)

      integration = %{
        base_url: "https://radicale.example.com",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :radicale
      }

      assert {:ok, _msg} =
               ProviderCommon.test_caldav_provider_connection(integration,
                 success_message: "ok",
                 unauthorized_message: "unauth",
                 not_found_message: "not found",
                 error_formatter: &inspect/1
               )

      assert_received {:propfind_url, "https://radicale.example.com/alice/"}
    end
  end
end
