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
  alias Tymeslot.Mailer.{SMTPAdapter, SMTPConfig}
  alias Tymeslot.Security.FieldValidators.EmailValidator

  require Logger

  @send_timeout_ms 20_000
  @type error ::
          Destination.error()
          | :authentication_failed
          | :tls_required
          | :delivery_failed
          | :timeout

  @doc "Sends an email using a validated, currently enabled user SMTP boundary."
  @spec deliver(Email.t(), map()) :: {:ok, term()} | {:error, error()}
  def deliver(email, candidate) do
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
    task = Tasks.async_nolink(Tymeslot.TaskSupervisor, fn -> send_safely(email, candidate) end)

    deadline = Application.get_env(:tymeslot, :email_send_deadline_ms, @send_timeout_ms)

    case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :delivery_failed}
      nil -> {:error, :timeout}
    end
  end

  defp send_safely(email, candidate) do
    destination = Application.get_env(:tymeslot, :user_smtp_destination_module, Destination)

    case destination.resolve(candidate.host, candidate.port) do
      {:ok, endpoint} ->
        email
        |> SMTPAdapter.deliver(adapter_config(candidate, endpoint))
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
  defp adapter_config(candidate, endpoint) do
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

  defp safe_result({:error, {:retries_exceeded, {:missing_requirement, _host, :auth}}}),
    do: {:error, :authentication_failed}

  defp safe_result({:error, {:no_more_hosts, {:permanent_failure, _host, :auth_failed}}}),
    do: {:error, :authentication_failed}

  defp safe_result({:error, {:retries_exceeded, {:missing_requirement, _host, :tls}}}),
    do: {:error, :tls_required}

  defp safe_result({:error, _reason}), do: {:error, :delivery_failed}
end
