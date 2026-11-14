defmodule Tymeslot.EmailSending.Transport do
  @moduledoc """
  Sends through a user SMTP account with mandatory TLS, AUTH, and DNS pinning.

  Configuration and credentials are runtime values only. The public boundary
  accepts no transport overrides. Trusted application configuration may replace
  the destination resolver and CA file for integration fixtures; user settings
  can never set either. Errors are fixed atoms so relay replies and credentials
  cannot escape through validation errors, task exits, or SMTP failures.
  """

  alias Swoosh.Email
  alias Tymeslot.EmailSending.Destination
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Mailer.{SMTPAdapter, SMTPConfig, SMTPResult}
  alias Tymeslot.Security.FieldValidators.EmailValidator

  require Logger

  @send_timeout_ms 20_000
  @type error ::
          Destination.error()
          | :authentication_failed
          | :tls_required
          | :delivery_failed
          | :timeout

  @type classified_error :: Destination.error() | SMTPResult.failure()

  @doc "Sends an email using a validated, currently enabled user SMTP boundary."
  @spec deliver(Email.t(), map()) :: {:ok, term()} | {:error, error()}
  def deliver(email, candidate) do
    case deliver_classified(email, candidate) do
      {:error, reason} when reason in [:session_timeout, :ambiguous_timeout] -> {:error, :timeout}
      {:error, :recipient_rejected} -> {:error, :delivery_failed}
      result -> result
    end
  end

  @doc """
  Sends with safe failure categories for the booking delivery pipeline.

  The caller applies its ambiguity policy after this function returns. A
  deadline before connection/TLS/AUTH completes is certainly unsent; after
  session opening the transaction may have reached the relay. No raw SMTP
  error, receipt, credential, or task exception escapes this boundary.
  """
  @spec deliver_classified(Email.t(), map()) :: {:ok, :accepted} | {:error, classified_error()}
  def deliver_classified(email, candidate) do
    cond do
      Application.get_env(:tymeslot, :user_smtp_enabled, false) != true ->
        {:error, :feature_disabled}

      not valid_email?(email) or not valid_candidate?(candidate) ->
        {:error, :invalid_settings}

      true ->
        deliver_with_deadline(email, candidate)
    end
  end

  defp valid_candidate?(%{
         host: host,
         port: port,
         security: security,
         username: username,
         password: password
       }) do
    Destination.valid_host?(host) and
      {port, security} in [{465, :implicit_tls}, {587, :starttls}] and
      valid_text?(username, 1024) and valid_text?(password, 4096)
  end

  defp valid_candidate?(_candidate), do: false

  defp valid_email?(%Email{from: {name, address}}) do
    valid_text?(address, 254) and EmailValidator.validate(address) == :ok and
      (name == "" or valid_text?(name, 255))
  end

  defp valid_email?(_email), do: false

  defp valid_text?(text, max_bytes) when is_binary(text) do
    byte_size(text) in 1..max_bytes and String.valid?(text) and
      not Regex.match?(~r/[\x00-\x1F\x7F]/u, text)
  end

  defp valid_text?(_text, _max_bytes), do: false

  defp deliver_with_deadline(email, candidate) do
    owner = self()
    reference = make_ref()

    # The SMTP task owns its socket and must die with a cancelled worker;
    # otherwise the owner's reservation could be freed while it still sends.
    # send_safely catches raw failures, and Task.shutdown unlinks before killing
    # a deadline-exceeded task, so neither path exposes credentials to callers.
    task =
      Tasks.async(Tymeslot.TaskSupervisor, fn ->
        send_safely(email, candidate, {owner, reference})
      end)

    deadline = Application.get_env(:tymeslot, :email_send_deadline_ms, @send_timeout_ms)

    result = Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill)
    session_opened? = session_opened?(reference)

    case result do
      {:ok, outcome} -> outcome
      {:exit, _reason} -> {:error, :delivery_failed}
      nil when session_opened? -> {:error, :ambiguous_timeout}
      nil -> {:error, :session_timeout}
    end
  end

  # A reference is unique to one send. Drain its notification on every result
  # so a long-lived caller cannot retain progress messages between deliveries.
  defp session_opened?(reference) do
    receive do
      {^reference, :smtp_session_opened} -> true
    after
      0 -> false
    end
  end

  defp send_safely(email, candidate, notification) do
    destination = Application.get_env(:tymeslot, :user_smtp_destination_module, Destination)

    case destination.resolve(candidate.host, candidate.port) do
      {:ok, endpoint} ->
        email
        |> SMTPAdapter.deliver(adapter_config(candidate, endpoint, notification))
        |> safe_result()

      {:error, reason}
      when reason in [:feature_disabled, :invalid_settings, :invalid_destination, :dns_failed] ->
        {:error, reason}

      _unexpected ->
        {:error, :delivery_failed}
    end
  rescue
    # Exceptions may contain SMTP credentials in their arguments. Never pass
    # the exception or stacktrace to a job, log, or caller-facing changeset.
    _error ->
      Logger.warning("User SMTP transport failed unexpectedly")
      {:error, :delivery_failed}
  catch
    _kind, _reason ->
      Logger.warning("User SMTP transport terminated unexpectedly")
      {:error, :delivery_failed}
  end

  # Build TLS options against the name, then replace only the network
  # target. A numeric relay and no MX lookups prevent a second DNS query.
  defp adapter_config(candidate, endpoint, notification) do
    SMTPConfig.build(
      host: candidate.host,
      port: candidate.port,
      ssl: candidate.security == :implicit_tls,
      username: candidate.username,
      password: candidate.password,
      tls_verify: :peer,
      cacertfile: Application.get_env(:tymeslot, :user_smtp_cacertfile),
      log_config: false
    )
    |> Keyword.put(:relay, endpoint.address |> :inet.ntoa() |> to_string())
    |> Keyword.put(:port, endpoint.port)
    |> Keyword.put(:require_auth, true)
    |> Keyword.put(:session_opened, notification)
    |> pin_address_family(endpoint.address)
  end

  # smtp_socket otherwise binds its IPv4 wildcard even for an IPv6 relay.
  # The original hostname's SNI and peer verification options stay intact.
  defp pin_address_family(config, address) when tuple_size(address) == 8 do
    Keyword.update(config, :sockopts, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 0}], fn options ->
      [:inet6 | Keyword.put(options, :ip, {0, 0, 0, 0, 0, 0, 0, 0})]
    end)
  end

  defp pin_address_family(config, _address), do: config

  defp safe_result({:ok, _receipt}), do: {:ok, :accepted}

  defp safe_result({:error, reason}), do: {:error, SMTPResult.classify(reason)}
end
