defmodule Tymeslot.Mailer.SMTPTlsTransportTest do
  @moduledoc """
  Drives a real TLS handshake through gen_smtp using the configuration
  `Tymeslot.Mailer.SMTPConfig` produces.

  The port-465 regression these tests guard was invisible at the
  configuration layer: the keyword list looked correct, and gen_smtp silently
  ignored half of it. Only an actual connection distinguishes the two.
  """

  use ExUnit.Case, async: true

  @moduletag :mailer
  @moduletag :integration

  alias Swoosh.Email
  alias Tymeslot.Mailer.{SMTPAdapter, SMTPConfig}
  alias Tymeslot.Test.FakeSmtpRelay

  # Generous on purpose. A tight budget here does not test anything: the
  # relay is an ordinary Erlang process, and if the suite is busy enough that
  # it is not scheduled into `:ssl.transport_accept/2` before the client gives
  # up, the client fails with `{:network_failure, _host, {:error, :timeout}}` —
  # indistinguishable from the relay refusing the certificate, and green or red
  # depending on machine load. Every outcome under test (a completed handshake,
  # a TLS alert) is reached in milliseconds once both sides are running, so
  # nothing waits for this bound except a genuine stall.
  @timeout 30_000

  # Certificate generation is the expensive part of this module — four RSA-2048
  # keypairs per chain — so both chains are built once for the module rather
  # than per test. Beyond the runtime saved, it keeps that work out of the
  # window in which the relay has to be scheduled.
  setup_all do
    %{
      trusted: relay_certificates(~c"localhost"),
      mismatched: relay_certificates(~c"elsewhere.example.com")
    }
  end

  describe "implicit TLS (port 465)" do
    test "connects when the relay's certificate chains to a trusted CA", %{trusted: certs} do
      relay = start_tls_relay(certs)

      assert {:ok, socket} = open(relay, cacertfile: relay.cacertfile)
      :gen_smtp_client.close(socket)
    end

    test "connects to an untrusted relay when verification is disabled", %{trusted: certs} do
      relay = start_tls_relay(certs)

      assert {:ok, socket} = open(relay, tls_verify: :none)
      :gen_smtp_client.close(socket)
    end

    test "rejects a relay no trust store validates", %{trusted: certs} do
      relay = start_tls_relay(certs)

      # A TLS alert, specifically: before the `:sockopts` fix this failed with
      # `{:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}`,
      # never reaching the certificate at all.
      assert {:error, :retries_exceeded,
              {:network_failure, _host, {:error, {:tls_alert, _alert}}}} = open(relay, [])
    end

    test "rejects a trusted CA's certificate issued for a different hostname", %{
      mismatched: certs
    } do
      relay = start_tls_relay(certs)

      assert {:error, :retries_exceeded,
              {:network_failure, _host, {:error, {:tls_alert, _alert}}}} =
               open(relay, cacertfile: relay.cacertfile)
    end

    # With the record in place — what an OTP relay always sends a client in
    # middlebox mode — nothing is retried and the session id says the mode was
    # on for the handshake that carried the mail.
    test "negotiates TLS 1.3 in the middlebox compatibility mode by default", %{
      trusted: certs
    } do
      relay = start_tls_relay(certs)

      assert {:ok, socket} = open(relay, cacertfile: relay.cacertfile)
      :gen_smtp_client.close(socket)

      assert_receive {:tls_up, info}, @timeout
      assert info.protocol == :"tlsv1.3"
      assert info.session_id != ""
    end
  end

  describe "a relay whose middlebox ChangeCipherSpec never arrives" do
    setup %{trusted: certs} do
      %{relay: certs |> start_tls_relay() |> FakeSmtpRelay.without_middlebox_record()}
    end

    test "aborts the handshake under the configuration a send starts from", %{relay: relay} do
      # OTP's client asserts a record RFC 8446 appendix D.4 leaves optional, so
      # the session fails before any message is sent — and on the STARTTLS path
      # gen_smtp collapses the alert to `:tls_failed`, which is indistinguishable
      # from a rejected certificate. Hence a retry rather than a diagnosis.
      assert {:error, :retries_exceeded,
              {:network_failure, _host, {:error, {:tls_alert, {:unexpected_message, _detail}}}}} =
               open(relay, cacertfile: relay.cacertfile)
    end

    @tag :capture_log
    test "delivers once the adapter retries without the compatibility mode", %{relay: relay} do
      assert {:ok, _receipt} =
               SMTPAdapter.deliver(email(), config(relay, cacertfile: relay.cacertfile))

      # Only the retry completes a handshake, and it completes it with the mode
      # off: an empty session id is the observable that says so.
      assert_receive {:tls_up, info}, @timeout
      assert info.protocol == :"tlsv1.3"
      assert info.session_id == ""
    end
  end

  # Builds the real production configuration for a port-465 relay, then points
  # it at the ephemeral test listener. Only the port and the credentials-free
  # dialogue are test scaffolding; every TLS option under test is the one
  # `SMTPConfig` produced.
  defp open(relay, extra) do
    relay
    |> config(extra)
    |> Keyword.drop([:adapter])
    |> :gen_smtp_client.open()
  end

  defp config(relay, extra) do
    [host: "localhost", port: 465, username: "user", password: "pass"]
    |> Keyword.merge(extra)
    |> SMTPConfig.build()
    |> Keyword.merge(
      port: relay.port,
      auth: :never,
      retries: 0,
      timeout: @timeout,
      session_timeout: @timeout
    )
  end

  defp email do
    Email.new(
      from: {"Tymeslot", "no-reply@example.com"},
      to: {"Booker", "booker@example.com"},
      subject: "Reminder",
      text_body: "See you tomorrow."
    )
  end

  defp relay_certificates(dns_name) do
    %{cert: cert, key: key, cacerts: cacerts} = certificates(dns_name)

    %{cert: cert, key: key, cacertfile: write_cacertfile(cacerts)}
  end

  defp start_tls_relay(%{cert: cert, key: key, cacertfile: cacertfile}) do
    {:ok, listen} =
      :ssl.listen(0, [
        :binary,
        cert: cert,
        key: key,
        active: false,
        packet: :line,
        reuseaddr: true
      ])

    {:ok, {_address, port}} = :ssl.sockname(listen)
    owner = self()
    # Unlinked: a relay that dies mid-handshake must fail the assertion under
    # test, not take the test process down with it.
    spawn(fn -> serve(listen, owner) end)
    on_exit(fn -> :ssl.close(listen) end)

    %{port: port, cacertfile: cacertfile}
  end

  # Serves one connection at a time until the listener closes, rather than
  # exiting after the first: a client whose handshake is refused reconnects to
  # try something else, and a relay that has already gone would fail that
  # second attempt for the wrong reason.
  defp serve(listen, owner) do
    with {:ok, socket} <- :ssl.transport_accept(listen, @timeout) do
      case :ssl.handshake(socket, @timeout) do
        {:ok, connection} ->
          {:ok, info} = :ssl.connection_information(connection)
          send(owner, {:tls_up, %{protocol: info[:protocol], session_id: info[:session_id]}})
          :ssl.send(connection, "220 localhost ESMTP test\r\n")
          dialogue(connection)

        {:error, _refused} ->
          :ok
      end

      serve(listen, owner)
    end
  end

  defp dialogue(connection) do
    case :ssl.recv(connection, 0, @timeout) do
      {:ok, "EHLO" <> _rest} ->
        :ssl.send(connection, "250-localhost\r\n250 SIZE 10240000\r\n")
        dialogue(connection)

      {:ok, "DATA" <> _rest} ->
        :ssl.send(connection, "354 End data with <CR><LF>.<CR><LF>\r\n")
        read_message(connection)
        :ssl.send(connection, "250 OK: queued as test\r\n")
        dialogue(connection)

      {:ok, "QUIT" <> _rest} ->
        :ssl.send(connection, "221 Bye\r\n")
        :ssl.close(connection)

      {:ok, _other} ->
        :ssl.send(connection, "250 OK\r\n")
        dialogue(connection)

      {:error, _reason} ->
        :ok
    end
  end

  # Swallows the message body, which ends on the lone dot of RFC 5321 §4.1.1.4.
  defp read_message(connection) do
    case :ssl.recv(connection, 0, @timeout) do
      {:ok, ".\r\n"} -> :ok
      {:ok, _line} -> read_message(connection)
      {:error, _reason} -> :ok
    end
  end

  # `:public_key.pkix_test_data/1` issues a throwaway CA and a leaf signed by
  # it, so the trusted and untrusted cases differ only in whether the client is
  # given the CA — no fixture files, no openssl binary.
  #
  # RSA/SHA-256 is specified rather than taken as the default: the default
  # chain is rejected outright by a TLS 1.3 server with
  # `unable_to_supply_acceptable_cert`, which would make every connection fail
  # and quietly turn the two rejection tests below green for the wrong reason.
  @key_params [key: {:rsa, 2048, 65_537}, digest: :sha256]

  defp certificates(dns_name) do
    subject_alt_name = {:Extension, {2, 5, 29, 17}, false, [dNSName: dns_name]}

    config =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: @key_params,
          intermediates: [],
          peer: @key_params ++ [extensions: [subject_alt_name]]
        },
        client_chain: %{root: @key_params, intermediates: [], peer: @key_params}
      })

    server = config[:server_config]
    %{cert: server[:cert], key: server[:key], cacerts: server[:cacerts]}
  end

  defp write_cacertfile(cacerts) do
    path =
      Path.join(System.tmp_dir!(), "tymeslot-test-ca-#{System.unique_integer([:positive])}.pem")

    pem = :public_key.pem_encode(Enum.map(cacerts, &{:Certificate, &1, :not_encrypted}))

    File.write!(path, pem)
    on_exit(fn -> File.rm(path) end)

    path
  end
end
