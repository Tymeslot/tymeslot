defmodule Tymeslot.Test.FakeSmtpRelay do
  @moduledoc """
  A scripted SMTP relay on a loopback port, for driving real gen_smtp sends
  and `Tymeslot.Mailer.SmtpProbe` against the failure modes a production
  relay produces.

  Mocking the adapter hides exactly the defects that matter here: how
  gen_smtp shapes its errors, what it does after a rejected login, and
  whether a TLS handshake succeeds. This relay speaks enough SMTP for all of
  them and reports what the client did to the process that started it:

    * `{:smtp_relay, :ehlo}` on each EHLO
    * `{:smtp_relay, {:tls_up, info}}` after a completed STARTTLS or
      implicit-TLS handshake, where `info` is `:ssl.connection_information/1`
      for the server side of it
    * `{:smtp_relay, {:auth, mechanism}}` on each AUTH attempt
    * `{:smtp_relay, {:mail_from, line}}` on MAIL FROM
    * `{:smtp_relay, {:message, data}}` once DATA is complete

  ## Options

    * `:greet` - `false` accepts the connection and never sends a greeting
      (default `true`)
    * `:auth` - `:accept`, `:reject`, or `:not_offered` (default `:accept`).
      After a rejected login MAIL FROM is refused with 530, as real relays do.
    * `:rcpt_reply` - the reply to RCPT TO (default `"250 OK"`)
    * `:after_data` - `:silent` takes the whole message and never acknowledges
      it, like a relay that stalls once delivery is under way (default `:ack`)
    * `:starttls` - certificates from `certificates/1`; advertises STARTTLS
    * `:implicit_tls` - certificates from `certificates/1`; TLS from the first byte
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @timeout 30_000

  # RSA/SHA-256 rather than the default chain, which a TLS 1.3 server rejects
  # with `unable_to_supply_acceptable_cert`, turning every rejection test green
  # for the wrong reason.
  @key_params [key: {:rsa, 2048, 65_537}, digest: :sha256]

  @spec start(keyword()) :: %{port: :inet.port_number()}
  def start(opts \\ []) do
    owner = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listen)
    # Unlinked: a relay that dies mid-dialogue must fail the assertion under
    # test, not take the test process down with it.
    spawn(fn -> accept_loop(listen, owner, Map.new(opts)) end)
    on_exit(fn -> :gen_tcp.close(listen) end)

    %{port: port}
  end

  @doc """
  Issues a throwaway CA and a leaf certificate for `dns_name`, and writes the
  CA to a PEM file for `SMTP_CACERTFILE`.
  """
  @spec certificates(charlist()) :: %{cert: binary(), key: term(), cacertfile: Path.t()}
  def certificates(dns_name \\ ~c"localhost") do
    subject_alt_name = {:Extension, {2, 5, 29, 17}, false, [dNSName: dns_name]}

    server =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: @key_params,
          intermediates: [],
          peer: @key_params ++ [extensions: [subject_alt_name]]
        },
        client_chain: %{root: @key_params, intermediates: [], peer: @key_params}
      })[:server_config]

    path =
      Path.join(System.tmp_dir!(), "tymeslot-relay-ca-#{System.unique_integer([:positive])}.pem")

    File.write!(
      path,
      :public_key.pem_encode(Enum.map(server[:cacerts], &{:Certificate, &1, :not_encrypted}))
    )

    on_exit(fn -> File.rm(path) end)

    %{cert: server[:cert], key: server[:key], cacertfile: path}
  end

  defp accept_loop(listen, owner, opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid =
          spawn(fn ->
            receive do
              :go -> session(socket, owner, opts)
            end
          end)

        :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop(listen, owner, opts)

      {:error, _closed} ->
        :ok
    end
  end

  defp session(socket, _owner, %{greet: false}) do
    # Hold the connection open without a word, like a relay expecting a TLS
    # handshake on a port the client treats as plain text.
    :gen_tcp.recv(socket, 0, @timeout)
  end

  defp session(socket, owner, %{implicit_tls: certs} = opts) do
    :ok = :inet.setopts(socket, packet: :raw)

    case :ssl.handshake(socket, tls_server_options(certs), @timeout) do
      {:ok, tls} ->
        send(owner, {:smtp_relay, {:tls_up, connection_information(tls)}})
        greet(%{socket: tls, mod: :ssl, tls?: true, authed?: false}, owner, opts)

      {:error, _reason} ->
        :ok
    end
  end

  defp session(socket, owner, opts) do
    greet(%{socket: socket, mod: :gen_tcp, tls?: false, authed?: false}, owner, opts)
  end

  defp greet(conn, owner, opts) do
    reply(conn, "220 localhost ESMTP fake relay")
    dialogue(conn, owner, opts)
  end

  defp dialogue(conn, owner, opts) do
    case conn.mod.recv(conn.socket, 0, @timeout) do
      {:ok, line} -> line |> String.trim_trailing() |> command(conn, owner, opts)
      {:error, _reason} -> :ok
    end
  end

  defp command("EHLO" <> _rest, conn, owner, opts) do
    send(owner, {:smtp_relay, :ehlo})

    extensions =
      Enum.reject(
        [
          "localhost",
          if(opts[:starttls] && not conn.tls?, do: "STARTTLS"),
          if(Map.get(opts, :auth, :accept) != :not_offered, do: "AUTH PLAIN LOGIN"),
          "8BITMIME"
        ],
        &is_nil/1
      )

    {last, rest} = List.pop_at(extensions, -1)
    Enum.each(rest, &reply(conn, "250-" <> &1))
    reply(conn, "250 " <> last)
    dialogue(conn, owner, opts)
  end

  defp command("STARTTLS", conn, owner, %{starttls: certs} = opts) do
    reply(conn, "220 Ready to start TLS")
    :ok = :inet.setopts(conn.socket, packet: :raw)

    case :ssl.handshake(conn.socket, tls_server_options(certs), @timeout) do
      {:ok, tls} ->
        send(owner, {:smtp_relay, {:tls_up, connection_information(tls)}})
        dialogue(%{conn | socket: tls, mod: :ssl, tls?: true}, owner, opts)

      {:error, _reason} ->
        :ok
    end
  end

  defp command("AUTH " <> mechanism, conn, owner, opts) do
    [name | _initial] = String.split(mechanism, " ")
    send(owner, {:smtp_relay, {:auth, String.upcase(name)}})

    if String.upcase(name) == "LOGIN" do
      reply(conn, "334 VXNlcm5hbWU6")
      conn.mod.recv(conn.socket, 0, @timeout)
      reply(conn, "334 UGFzc3dvcmQ6")
      conn.mod.recv(conn.socket, 0, @timeout)
    end

    case Map.get(opts, :auth, :accept) do
      :accept ->
        reply(conn, "235 2.7.0 Authentication successful")
        dialogue(%{conn | authed?: true}, owner, opts)

      :reject ->
        reply(conn, "535 5.7.8 Authentication credentials invalid")
        dialogue(conn, owner, opts)
    end
  end

  defp command("MAIL FROM:" <> _rest = line, conn, owner, opts) do
    send(owner, {:smtp_relay, {:mail_from, line}})

    if Map.get(opts, :auth) == :reject and not conn.authed? do
      reply(conn, "530 5.7.0 Authentication required")
    else
      reply(conn, "250 OK")
    end

    dialogue(conn, owner, opts)
  end

  defp command("RCPT TO:" <> _rest, conn, owner, opts) do
    reply(conn, Map.get(opts, :rcpt_reply, "250 OK"))
    dialogue(conn, owner, opts)
  end

  defp command("DATA", conn, owner, opts) do
    reply(conn, "354 End data with <CR><LF>.<CR><LF>")
    send(owner, {:smtp_relay, {:message, read_data(conn, [])}})

    case Map.get(opts, :after_data, :ack) do
      :silent ->
        conn.mod.recv(conn.socket, 0, @timeout)

      :ack ->
        reply(conn, "250 2.0.0 Ok: queued")
        dialogue(conn, owner, opts)
    end
  end

  defp command("QUIT", conn, _owner, _opts) do
    reply(conn, "221 Bye")
    conn.mod.close(conn.socket)
  end

  defp command(_other, conn, owner, opts) do
    reply(conn, "250 OK")
    dialogue(conn, owner, opts)
  end

  defp read_data(conn, acc) do
    case conn.mod.recv(conn.socket, 0, @timeout) do
      {:ok, ".\r\n"} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, line} -> read_data(conn, [line | acc])
      {:error, _reason} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp reply(conn, line), do: conn.mod.send(conn.socket, line <> "\r\n")

  defp tls_server_options(%{cert: cert, key: key}) do
    [cert: cert, key: key, active: false, packet: :line, mode: :binary]
  end

  # The negotiated protocol and the session id the client offered. Under TLS
  # 1.3 the latter is the middlebox compatibility mode made observable: a
  # client in that mode invents a 32-byte id purely so the exchange resembles
  # a TLS 1.2 one, and a client with it switched off sends none at all.
  defp connection_information(socket) do
    {:ok, info} = :ssl.connection_information(socket)

    %{protocol: info[:protocol], session_id: info[:session_id]}
  end
end
