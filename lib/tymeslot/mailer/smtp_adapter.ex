defmodule Tymeslot.Mailer.SMTPAdapter do
  @moduledoc """
  Swoosh SMTP adapter that keeps opening the session apart from sending the
  message, so a hung relay can be told apart from a slow delivery.

  `Swoosh.Adapters.SMTP` runs the whole exchange in one gen_smtp call, which
  waits a fixed 20 minutes for every reply. When a caller gives up on it, a
  relay that never greeted and a relay that went quiet after accepting the
  message look identical from outside, and the safe answer for the second
  (assume it was delivered, so a retry cannot duplicate it) silently drops
  every email behind the first.

  Here the session is opened first (connect, greeting, EHLO, STARTTLS, AUTH)
  under its own deadline, `:session_timeout` (default 15 seconds). No message
  data has been sent at that point, so running out of time there is reported
  exactly as gen_smtp reports a connection timeout,
  `{:retries_exceeded, {:network_failure, host, {:error, :timeout}}}`, which
  `Tymeslot.Emails.Delivery` retries. Only a hang once the transaction has
  begun is left to `Delivery`'s overall send deadline, which treats it as
  possibly delivered.

  The configuration is `Swoosh.Adapters.SMTP`'s, and the message is encoded
  by the same helpers, so what reaches the relay is unchanged. Errors keep
  that adapter's shapes too: a failure inside the transaction is
  `{:send, {type, host, message}}`.
  """

  use Swoosh.Adapter, required_config: [:relay], required_deps: [gen_smtp: :gen_smtp_client]

  require Logger
  require Record

  alias Swoosh.Adapters.SMTP
  alias Swoosh.Adapters.SMTP.Helpers
  alias Swoosh.Email

  # Mirrors gen_smtp_client's `#smtp_client_socket{}` record, so the socket and
  # host are read by field name rather than by tuple position.
  Record.defrecordp(:smtp_client_socket, [:socket, :host, :extensions, :options])

  @default_session_timeout_ms 15_000

  @impl Swoosh.Adapter
  def deliver(%Email{} = email, config) do
    options = SMTP.gen_smtp_config(config)

    with {:ok, client} <- open_session(options, config) do
      message = {Helpers.sender(email), recipients(email), Helpers.body(email, config)}

      try do
        case :gen_smtp_client.deliver(client, message) do
          {:ok, receipt} ->
            {:ok, receipt}

          {:error, {type, reason}} ->
            {:error, {:send, {type, smtp_client_socket(client, :host), reason}}}
        end
      after
        :gen_smtp_client.close(client)
      end
    end
  end

  # gen_smtp opens the socket in the calling process, so the session is opened
  # in a task the deadline can kill (closing the half-open socket with it) and
  # the socket is handed back to this process on success.
  defp open_session(options, config) do
    owner = self()
    timeout = Keyword.get(config, :session_timeout, @default_session_timeout_ms)
    task = Task.async(fn -> open_owned_by(options, owner) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, client}} ->
        {:ok, client}

      {:ok, {:error, type, details}} ->
        {:error, {type, details}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error,
         {:retries_exceeded, {:network_failure, to_charlist(config[:relay]), {:error, :timeout}}}}
    end
  end

  # `auth: :always` makes a rejected login fail loudly, but it also refuses a
  # relay that offers no AUTH at all, which `:if_available` used to send to
  # without logging in. Credentials left configured for such a relay are a
  # harmless leftover rather than a wrong password, so that one case is
  # reopened without a login instead of failing every send. Stripping AUTH
  # from the relay's reply can only make the session unauthenticated, never
  # expose the credentials.
  defp open_owned_by(options, owner) do
    case :gen_smtp_client.open(options) do
      {:ok, client} ->
        :ok = :smtp_socket.controlling_process(smtp_client_socket(client, :socket), owner)
        {:ok, client}

      {:error, :retries_exceeded, {:missing_requirement, host, :auth}} ->
        Logger.warning(
          "SMTP relay does not offer authentication; sending without logging in. " <>
            "Unset SMTP_USERNAME and SMTP_PASSWORD if the relay authorises by network.",
          relay: to_string(host)
        )

        options |> Keyword.put(:auth, :never) |> open_owned_by(owner)

      error ->
        error
    end
  end

  defp recipients(email) do
    [email.to, email.cc, email.bcc]
    |> Enum.concat()
    |> Enum.map(fn {_name, address} -> address end)
    |> Enum.uniq()
  end
end
