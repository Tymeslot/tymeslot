defmodule Tymeslot.Integrations.Calendar.Exchange.CircuitBreakerTest do
  @moduledoc """
  Covers the circuit breaker every EWS request runs through.

  Exchange is self-hosted, so what the breaker has to get right is *whose*
  failure it is counting. A server that has stopped answering must stop being
  called, or every integration on it re-runs a long-timeout request on every
  sync cycle for as long as it stays down. One organiser's rejected password,
  wrong endpoint or malformed request must count for nothing, because the
  breaker it would trip is shared with everyone else on that same server.

  The refusals asserted here are always checked against a server that is
  answering normally again, so a passing assertion cannot be the transport
  failing by coincidence.
  """

  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Exchange.Client

  @find_folder "<m:FindFolder/>"

  # Read from the configuration rather than restated, so retuning the provider
  # retunes these tests with it.
  @threshold CalendarCircuitBreaker.get_config(:exchange).failure_threshold

  describe "failures that say the server is unwell" do
    test "a run of transport failures opens the breaker" do
      stub_transport_error()

      for _attempt <- 1..@threshold do
        assert {:error, :network_error} = Client.call(config(), @find_folder)
      end

      # The server is answering again, so the refusal below can only be the
      # breaker's. Without this the assertion would pass on the transport
      # still being broken.
      respond_with(200, ok_envelope())

      assert {:error, :circuit_open} = Client.call(config(), @find_folder)
    end

    test "a run of 5xx responses opens the breaker" do
      respond_with(503, "Service Unavailable")

      for _attempt <- 1..@threshold do
        assert {:error, :server_error} = Client.call(config(), @find_folder)
      end

      respond_with(200, ok_envelope())

      assert {:error, :circuit_open} = Client.call(config(), @find_folder)
    end

    test "an open breaker answers without issuing a request" do
      test_pid = self()

      reporting_stub = fn conn ->
        send(test_pid, :request_issued)

        conn
        |> Conn.put_resp_content_type("text/xml")
        |> Conn.resp(200, ok_envelope())
      end

      # Anchors the refutation: while the breaker is closed this stub really
      # does report the request, so an unwired breaker would fail below rather
      # than pass on a message that was never sent in the first place.
      ReqTest.stub(:tymeslot_http, reporting_stub)
      assert {:ok, _doc} = Client.call(config(), @find_folder)
      assert_received :request_issued

      trip_breaker()
      ReqTest.stub(:tymeslot_http, reporting_stub)

      assert {:error, :circuit_open} = Client.call(config(), @find_folder)
      refute_received :request_issued
    end
  end

  describe "failures that belong to one integration" do
    test "a rejected credential never opens the breaker, however often it is rejected" do
      respond_with(401, "Unauthorized")

      for _attempt <- 1..(@threshold * 2) do
        assert {:error, :unauthorized} = Client.call(config(), @find_folder)
      end

      # Still closed, so the next caller reaches the server. A breaker opened
      # by one organiser's stale password would refuse every other mailbox on
      # the same Exchange server.
      respond_with(200, ok_envelope())

      assert {:ok, _doc} = Client.call(config(), @find_folder)
    end

    test "a refusal, a missing endpoint, a fault or an unmodelled status never opens it" do
      failures = [
        {403, "Forbidden", :forbidden},
        {404, "Not Found", :not_found},
        {500, fault_envelope("ErrorSchemaValidation"), {:soap_fault, "ErrorSchemaValidation"}},
        {415, "Unsupported Media Type", {:unexpected_status, 415}},
        {200, "<html><body>Sign in", :malformed_xml}
      ]

      # More failures than the threshold, so a breaker counting any of them
      # would be open by the end.
      assert length(failures) > @threshold

      for {status, body, expected} <- failures do
        respond_with(status, body)

        assert {:error, ^expected} = Client.call(config(), @find_folder)
      end

      respond_with(200, ok_envelope())

      assert {:ok, _doc} = Client.call(config(), @find_folder)
    end
  end

  describe "keying" do
    test "one server's outage does not refuse another server's reads" do
      other_url = "https://mail2.example.com/EWS/Exchange.asmx"
      on_exit(fn -> reset_breaker(other_url) end)

      trip_breaker()
      respond_with(200, ok_envelope())

      assert {:error, :circuit_open} = Client.call(config(), @find_folder)

      assert {:ok, _doc} = Client.call(config(base_url: other_url), @find_folder)
    end
  end

  defp stub_transport_error do
    ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, :econnrefused) end)
  end

  defp trip_breaker do
    stub_transport_error()

    for _attempt <- 1..@threshold do
      assert {:error, :network_error} = Client.call(config(), @find_folder)
    end

    :ok
  end
end
