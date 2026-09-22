defmodule Tymeslot.Mailer.SmtpProbeTest do
  # async: false — tests open real TCP listeners on loopback; running concurrently
  # risks port collisions and makes test output harder to read.
  use ExUnit.Case, async: false
  @moduletag :mailer

  import ExUnit.CaptureLog

  alias Tymeslot.Mailer.SMTPConfig
  alias Tymeslot.Mailer.SmtpProbe
  alias Tymeslot.Test.FakeSmtpRelay

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Opens a loopback TCP listener, runs the probe against it, then closes.
  # `greeting_fn` receives the accepted socket and is responsible for sending
  # the initial server greeting (and nothing else — the probe sends QUIT and
  # the listener drains without asserting).
  defp with_tcp_listener(port \\ 0, greeting_fn) do
    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_ip, actual_port}} = :inet.sockname(listen_socket)

    server_task =
      Task.async(fn ->
        {:ok, client_socket} = :gen_tcp.accept(listen_socket, 3_000)
        greeting_fn.(client_socket)
        # Drain the QUIT command and close — we don't assert on it here.
        :gen_tcp.recv(client_socket, 0, 1_000)
        :gen_tcp.close(client_socket)
      end)

    result = {actual_port, listen_socket, server_task}
    result
  end

  defp stop_listener({_port, listen_socket, server_task}) do
    Task.await(server_task, 3_000)
    :gen_tcp.close(listen_socket)
  end

  # `tls: :never`: these listeners only greet, so the probe must not go on to
  # negotiate STARTTLS with them.
  defp valid_config(port) do
    [
      relay: "127.0.0.1",
      port: port,
      username: "user",
      password: "pass",
      tls: :never
    ]
  end

  # The production configuration for `localhost`, pointed at a test relay.
  defp relay_config(relay, opts) do
    [host: "localhost", port: 587, username: "user", password: "pass"]
    |> Keyword.merge(opts)
    |> SMTPConfig.build()
    |> Keyword.put(:port, relay.port)
  end

  # ---------------------------------------------------------------------------
  # DNS resolution failure
  # ---------------------------------------------------------------------------

  describe "test_connection/1 — DNS resolution" do
    test "returns an error when the relay hostname does not resolve" do
      config = [
        relay: "nonexistent.invalid",
        port: 587,
        username: "user",
        password: "pass"
      ]

      log =
        capture_log(fn ->
          result = SmtpProbe.test_connection(config)
          assert {:error, message} = result
          assert message =~ "nonexistent.invalid"
          assert message =~ "587"
          assert message =~ "DNS"
        end)

      assert log =~ "SMTP connection test failed"
    end
  end

  # ---------------------------------------------------------------------------
  # Port 587 (STARTTLS path — plain TCP greeting)
  # ---------------------------------------------------------------------------

  describe "test_connection/1 — STARTTLS" do
    setup do
      %{certs: FakeSmtpRelay.certificates()}
    end

    test "passes when the upgraded connection presents a trusted certificate", %{certs: certs} do
      relay = FakeSmtpRelay.start(starttls: certs)

      capture_log(fn ->
        assert :ok = SmtpProbe.test_connection(relay_config(relay, cacertfile: certs.cacertfile))
      end)

      assert_receive {:smtp_relay, {:tls_up, _info}}
    end

    # The probe used to stop at the plain-text greeting, reporting the mailer
    # healthy while every send failed this handshake.
    test "fails when no trust store validates the relay's certificate", %{certs: certs} do
      relay = FakeSmtpRelay.start(starttls: certs)

      capture_log(fn ->
        assert {:error, message} = SmtpProbe.test_connection(relay_config(relay, []))
        assert message =~ "SSL/TLS alert"
        assert message =~ "SMTP_CACERTFILE"
      end)
    end

    test "fails when a port that requires STARTTLS is not offered it" do
      relay = FakeSmtpRelay.start()

      capture_log(fn ->
        assert {:error, message} = SmtpProbe.test_connection(relay_config(relay, []))
        assert message =~ "does not offer STARTTLS"
        assert message =~ "SMTP_SSL=true"
      end)
    end

    # The probe restated the sender's TLS options instead of taking them, so an
    # option the sender gained went missing here and the probe handshook
    # differently from the send it is meant to predict. The session id is what
    # the compatibility mode controls and what a relay decides from, so it is
    # the observable for both.
    test "handshakes with the middlebox compatibility mode the sender uses",
         %{certs: certs} do
      relay = FakeSmtpRelay.start(starttls: certs)

      capture_log(fn ->
        assert :ok = SmtpProbe.test_connection(relay_config(relay, cacertfile: certs.cacertfile))
      end)

      assert_receive {:smtp_relay, {:tls_up, info}}
      assert info.protocol == :"tlsv1.3"
      assert info.session_id != ""
    end

    # Without the same retry the sender makes, the probe would report a relay
    # broken at every boot while every email it sends goes through.
    test "passes on a relay whose middlebox record never arrives", %{certs: certs} do
      relay =
        [starttls: certs] |> FakeSmtpRelay.start() |> FakeSmtpRelay.without_middlebox_record()

      capture_log(fn ->
        assert :ok = SmtpProbe.test_connection(relay_config(relay, cacertfile: certs.cacertfile))
      end)

      assert_receive {:smtp_relay, {:tls_up, info}}
      assert info.session_id == ""
    end
  end

  describe "test_connection/1 — implicit TLS" do
    setup do
      %{certs: FakeSmtpRelay.certificates()}
    end

    test "passes against a trusted certificate on any port with ssl: true", %{certs: certs} do
      relay = FakeSmtpRelay.start(implicit_tls: certs)
      config = relay_config(relay, ssl: true, cacertfile: certs.cacertfile)

      capture_log(fn -> assert :ok = SmtpProbe.test_connection(config) end)
      assert_receive {:smtp_relay, {:tls_up, _info}}
    end

    test "fails when no trust store validates the relay's certificate", %{certs: certs} do
      relay = FakeSmtpRelay.start(implicit_tls: certs)

      capture_log(fn ->
        assert {:error, message} = SmtpProbe.test_connection(relay_config(relay, ssl: true))
        assert message =~ "SSL/TLS alert"
      end)
    end
  end

  describe "test_connection/1 — port 587 TCP greeting" do
    test "returns :ok when the server sends a valid 220 ESMTP greeting" do
      {port, listen_socket, server_task} =
        with_tcp_listener(fn client_socket ->
          :gen_tcp.send(client_socket, "220 mail.example.com ESMTP ready\r\n")
        end)

      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log([level: :info], fn ->
          assert :ok = SmtpProbe.test_connection(valid_config(port))
        end)

      Logger.configure(level: original_level)

      assert log =~ "SMTP connection test passed"
      stop_listener({port, listen_socket, server_task})
    end

    test "returns :ok when the server sends a 220 greeting without SMTP/ESMTP keyword" do
      # The probe logs a debug notice but still returns :ok.
      {port, listen_socket, server_task} =
        with_tcp_listener(fn client_socket ->
          :gen_tcp.send(client_socket, "220 mail.example.com ready\r\n")
        end)

      capture_log(fn ->
        assert :ok = SmtpProbe.test_connection(valid_config(port))
      end)

      stop_listener({port, listen_socket, server_task})
    end

    test "returns an error when the server sends a non-220 greeting" do
      {port, listen_socket, server_task} =
        with_tcp_listener(fn client_socket ->
          :gen_tcp.send(client_socket, "554 Service unavailable\r\n")
        end)

      capture_log(fn ->
        assert {:error, message} = SmtpProbe.test_connection(valid_config(port))
        assert message =~ "Cannot connect to 127.0.0.1:#{port}"
        assert message =~ "Invalid SMTP greeting (expected 220 code)"
        assert message =~ "554 Service unavailable"
      end)

      stop_listener({port, listen_socket, server_task})
    end

    test "returns an error when the server refuses the connection" do
      # Pick a port with nothing listening.
      {:ok, tmp} = :gen_tcp.listen(0, [:binary, reuseaddr: true, ip: {127, 0, 0, 1}])
      {:ok, {_addr, unused_port}} = :inet.sockname(tmp)
      :gen_tcp.close(tmp)

      capture_log(fn ->
        assert {:error, message} = SmtpProbe.test_connection(valid_config(unused_port))
        assert message =~ "127.0.0.1"
        # Could be "Connection refused" or "timed out" depending on OS
        assert message =~ "127.0.0.1"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Port 465 (direct SSL path)
  # ---------------------------------------------------------------------------

  describe "test_connection/1 — port 465 SSL path" do
    test "returns an error when the relay hostname does not resolve (DNS failure)" do
      config = [
        relay: "ssl-nonexistent.invalid",
        port: 465,
        username: "user",
        password: "pass"
      ]

      capture_log(fn ->
        assert {:error, message} = SmtpProbe.test_connection(config)
        assert message =~ "ssl-nonexistent.invalid"
        assert message =~ "465"
        assert message =~ "DNS"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Error message formatting
  # ---------------------------------------------------------------------------

  describe "error message formatting" do
    test "connection refused on port 587 includes STARTTLS suggestion" do
      {:ok, tmp} = :gen_tcp.listen(0, [:binary, reuseaddr: true, ip: {127, 0, 0, 1}])
      {:ok, {_addr, _port}} = :inet.sockname(tmp)
      :gen_tcp.close(tmp)

      config = [relay: "127.0.0.1", port: 587, username: "user", password: "pass"]

      capture_log(fn ->
        # Loopback with nothing bound refuses immediately, so the port-specific
        # suggestion arm is the deterministic outcome here.
        assert {:error, message} = SmtpProbe.test_connection(config)
        assert message =~ "Cannot connect to 127.0.0.1:587: Connection refused"
        assert message =~ "Port 587 (STARTTLS) connection refused"
        assert message =~ "Try port 465 (SSL) instead: SMTP_PORT=465"
      end)
    end
  end
end
