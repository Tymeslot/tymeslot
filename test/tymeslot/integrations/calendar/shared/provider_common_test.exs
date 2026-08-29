defmodule Tymeslot.Integrations.Calendar.Shared.ProviderCommonTest do
  use ExUnit.Case, async: true

  import Mox
  import Tymeslot.CalDAVTestHelpers

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

    test "reason-specific copy beats the provider's own error formatter" do
      # The formatters are fallbacks that know the brand, not the failure, and
      # they differ in shape between providers (some sanitise, some render
      # `inspect/1` into the flash). A reason `ErrorMessages` has copy for must
      # not reach any of them, so the check lives at this choke point rather
      # than in each formatter, where only some would ever get it.
      Mox.stub(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, _headers, _opts ->
        cond do
          String.ends_with?(url, "/dav/") ->
            {:ok, %Req.Response{status: 207, body: principal_xml("/dav/principals/alice/")}}

          String.ends_with?(url, "/principals/alice/") ->
            {:ok, %Req.Response{status: 207, body: calendar_home_set_xml("/dav/cals/alice/")}}

          # Including the guessed discovery path, which is what sends discovery
          # down the RFC 4791 chain, and the calendar home at the end of it.
          true ->
            {:ok, %Req.Response{status: 404, body: ""}}
        end
      end)

      integration = %{
        base_url: "https://caldav.example.com/dav",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :caldav
      }

      assert {:error, message} = connection_test(integration)

      assert message =~ "https://caldav.example.com/dav"
      assert message =~ "credentials were accepted"
      refute message =~ "formatter said"
    end

    test "a reason with no specific copy still reaches the formatter" do
      Mox.stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: ""}}
      end)

      integration = %{
        base_url: "https://caldav.example.com/dav",
        username: "alice",
        password: "secret",
        calendar_paths: [],
        provider: :caldav
      }

      assert {:error, "formatter said: :rate_limited"} = connection_test(integration)
    end
  end

  defp connection_test(integration) do
    ProviderCommon.test_caldav_provider_connection(integration,
      success_message: "ok",
      unauthorized_message: "unauth",
      not_found_message: "not found",
      error_formatter: fn reason -> "formatter said: #{inspect(reason)}" end
    )
  end
end
