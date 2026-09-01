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

  describe "implicit TLS (port 465)" do
    test "connects when the relay's certificate chains to a trusted CA" do
      relay = start_tls_relay()

      assert {:ok, socket} = open(relay, cacertfile: relay.cacertfile)
      :gen_smtp_client.close(socket)
    end

    test "connects to an untrusted relay when verification is disabled" do
      relay = start_tls_relay()

      assert {:ok, socket} = open(relay, tls_verify: :none)
      :gen_smtp_client.close(socket)
    end

    test "rejects a relay no trust store validates" do
      relay = start_tls_relay()

      # A TLS alert, specifically: before the `:sockopts` fix this failed with
      # `{:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}`,
      # never reaching the certificate at all.
      assert {:error, :retries_exceeded,
              {:network_failure, _host, {:error, {:tls_alert, _alert}}}} = open(relay, [])
    end

    test "rejects a trusted CA's certificate issued for a different hostname" do
      relay = start_tls_relay(dns_name: ~c"elsewhere.example.com")

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
    |> Keyword.merge(port: relay.port, auth: :never, retries: 0, timeout: 5_000)
    |> :gen_smtp_client.open()
  end

  defp start_tls_relay(opts \\ []) do
    dns_name = Keyword.get(opts, :dns_name, ~c"localhost")
    %{cert: cert, key: key, cacerts: cacerts} = certificates(dns_name)

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

    %{port: port, cacertfile: write_cacertfile(cacerts)}
  end

  defp serve(listen) do
    with {:ok, socket} <- :ssl.transport_accept(listen, 5_000),
         {:ok, connection} <- :ssl.handshake(socket, 5_000) do
      :ssl.send(connection, "220 localhost ESMTP test\r\n")
      dialogue(connection)
    end
  end

  defp dialogue(connection) do
    case :ssl.recv(connection, 0, 5_000) do
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
