defmodule Tymeslot.Mailer.ApiProbeTest do
  # async: false — :meck patches the Finch module globally for the duration of
  # each test, which is incompatible with concurrent test execution.
  use ExUnit.Case, async: false
  @moduletag :mailer

  import ExUnit.CaptureLog

  alias Tymeslot.Mailer.ApiProbe

  @sendgrid_config [api_key: "SG.test-key"]

  # The application supervisor starts `Tymeslot.Finch` in test, so
  # `Process.whereis(Tymeslot.Finch)` is already non-nil and `run/3` reaches the
  # request. Finch.request/3 is patched via :meck to avoid real network traffic.
  setup do
    unload_if_loaded(Finch)
    :meck.new(Finch, [:passthrough])

    on_exit(fn -> unload_if_loaded(Finch) end)

    :ok
  end

  defp unload_if_loaded(module) do
    :meck.unload(module)
  rescue
    _error -> :ok
  end

  defp respond(status, body \\ "{}") do
    :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
      {:ok, %Finch.Response{status: status, headers: [], body: body}}
    end)
  end

  defp capture_request do
    test_pid = self()

    :meck.expect(Finch, :request, fn req, Tymeslot.Finch, _opts ->
      send(test_pid, {:finch_request, req})
      {:ok, %Finch.Response{status: 200, headers: [], body: "{}"}}
    end)
  end

  describe "run/3 — response branches" do
    test "returns :ok on a 200 response" do
      respond(200)

      capture_log(fn ->
        assert :ok = ApiProbe.run(:sendgrid, "SendGrid", @sendgrid_config)
      end)
    end

    test "returns an error on 401, naming the provider" do
      respond(401, "")

      capture_log(fn ->
        assert {:error, message} = ApiProbe.run(:sendgrid, "SendGrid", @sendgrid_config)
        assert message =~ "SendGrid"
        assert message =~ "401"
      end)
    end

    test "passes on 403, because a send-only key cannot read the probe endpoint" do
      respond(403, "")

      log =
        capture_log(fn ->
          assert :ok = ApiProbe.run(:sendgrid, "SendGrid", @sendgrid_config)
        end)

      assert log =~ "lacks permission"
      assert log =~ "Sending is unaffected"
    end

    test "returns an error on 404, pointing at the domain or account identifier" do
      respond(404, "")

      capture_log(fn ->
        assert {:error, message} =
                 ApiProbe.run(:mailgun, "Mailgun", api_key: "key", domain: "mg.example.com")

        assert message =~ "404"
        assert message =~ "domain or account identifier"
      end)
    end

    test "returns an error on an unexpected status" do
      respond(500, "Internal Server Error")

      capture_log(fn ->
        assert {:error, message} = ApiProbe.run(:sendgrid, "SendGrid", @sendgrid_config)
        assert message =~ "unexpected status: 500"
      end)
    end

    test "returns an error on a network timeout" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:error, %{reason: :timeout}}
      end)

      capture_log(fn ->
        assert {:error, message} = ApiProbe.run(:sendgrid, "SendGrid", @sendgrid_config)
        assert message =~ "Timeout connecting to SendGrid"
      end)
    end

    test "returns an error on a transport failure" do
      :meck.expect(Finch, :request, fn _req, Tymeslot.Finch, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      capture_log(fn ->
        assert {:error, message} = ApiProbe.run(:sendgrid, "SendGrid", @sendgrid_config)
        assert message =~ "Cannot connect to SendGrid"
      end)
    end

    test "the :none probe issues no request at all" do
      :meck.expect(Finch, :request, fn _req, _name, _opts ->
        flunk("adapters without a probe must not call out")
      end)

      assert :ok = ApiProbe.run(:none, "Test", [])
    end
  end

  describe "run/3 — request construction" do
    test "Postmark sends the server token in its own header" do
      capture_request()

      capture_log(fn -> ApiProbe.run(:postmark, "Postmark", api_key: "my-secret-key") end)

      assert_receive {:finch_request, req}
      assert req.method == "GET"
      assert req.host == "api.postmarkapp.com"
      assert req.path == "/server"
      assert {"X-Postmark-Server-Token", "my-secret-key"} in req.headers
    end

    test "SendGrid authenticates as a bearer token against the scopes endpoint" do
      capture_request()

      capture_log(fn -> ApiProbe.run(:sendgrid, "SendGrid", api_key: "SG.key") end)

      assert_receive {:finch_request, req}
      assert req.host == "api.sendgrid.com"
      assert req.path == "/v3/scopes"
      assert {"Authorization", "Bearer SG.key"} in req.headers
    end

    test "Mailgun checks the configured domain with basic auth" do
      capture_request()

      capture_log(fn ->
        ApiProbe.run(:mailgun, "Mailgun", api_key: "key", domain: "mg.example.com")
      end)

      assert_receive {:finch_request, req}
      assert req.host == "api.mailgun.net"
      assert req.path == "/v3/domains/mg.example.com"
      assert {"Authorization", "Basic #{Base.encode64("api:key")}"} in req.headers
    end

    test "Mailgun honours the EU base URL" do
      capture_request()

      capture_log(fn ->
        ApiProbe.run(:mailgun, "Mailgun",
          api_key: "key",
          domain: "mg.example.com",
          base_url: "https://api.eu.mailgun.net/v3"
        )
      end)

      assert_receive {:finch_request, req}
      assert req.host == "api.eu.mailgun.net"
      assert req.path == "/v3/domains/mg.example.com"
    end

    test "AhaSend pings, which needs no send scope and delivers nothing" do
      capture_request()

      capture_log(fn ->
        ApiProbe.run(:ahasend, "AhaSend", api_key: "aha-sk-key", account_id: "acct-1")
      end)

      assert_receive {:finch_request, req}
      assert req.method == "GET"
      assert req.host == "api.ahasend.com"
      assert req.path == "/v2/ping"
      assert {"Authorization", "Bearer aha-sk-key"} in req.headers
    end
  end
end
