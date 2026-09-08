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

  alias Tymeslot.Mailer.SMTPConfig

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
  end

  # Builds the real production configuration for a port-465 relay, then points
  # it at the ephemeral test listener. Only the port and the credentials-free
  # dialogue are test scaffolding; every TLS option under test is the one
  # `SMTPConfig` produced.
  defp open(relay, extra) do
    [host: "localhost", port: 465, username: "user", password: "pass"]
    |> Keyword.merge(extra)
    |> SMTPConfig.build()
    |> Keyword.drop([:adapter])
    |> Keyword.merge(port: relay.port, auth: :never, retries: 0, timeout: @timeout)
    |> :gen_smtp_client.open()
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
    # Unlinked: a relay that dies mid-handshake must fail the assertion under
    # test, not take the test process down with it.
    spawn(fn -> serve(listen) end)
    on_exit(fn -> :ssl.close(listen) end)

    %{port: port, cacertfile: cacertfile}
  end

  defp serve(listen) do
    with {:ok, socket} <- :ssl.transport_accept(listen, @timeout),
         {:ok, connection} <- :ssl.handshake(socket, @timeout) do
      :ssl.send(connection, "220 localhost ESMTP test\r\n")
      dialogue(connection)
    end
  end

  defp dialogue(connection) do
    case :ssl.recv(connection, 0, @timeout) do
      {:ok, "EHLO" <> _rest} ->
        :ssl.send(connection, "250-localhost\r\n250 SIZE 10240000\r\n")
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
