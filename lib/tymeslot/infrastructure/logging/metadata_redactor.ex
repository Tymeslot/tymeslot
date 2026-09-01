defmodule Tymeslot.Infrastructure.Logging.MetadataRedactor do
  @moduledoc """
  Erlang `:logger` primary filter that scrubs sensitive keys from inline
  Logger metadata before they reach any handler or formatter.

  This is defence in depth on top of `Tymeslot.Infrastructure.Logging.Redactor`
  (which scrubs message strings on opt-in). Even a careless

      Logger.error("oauth failed", api_key: secret, password: pw)

  ships `[REDACTED]` to stdout instead of leaking the secret.

  Sensitive keys are matched case-insensitively against the metadata key name
  (atom or string). Substring matching catches variants like `stripe_api_key`,
  `refresh_token`, `set_cookie`, `x_authorization`.

  Personal identifiers (`email`, `identifier`) are matched more precisely than
  secrets, because "email" appears in plenty of key names that carry no address
  at all. See `@sensitive_key_suffixes` and `@sensitive_exact_keys` below.

  A key whose value the writer has already masked is named with a `_masked`
  suffix by convention (`email_masked`, `owner_email_masked`,
  `identifier_masked`); none of the rules below matches such a key, so the
  masked value survives to the log line. Masking at source is the primary
  defence — this filter only catches what a call site forgot.
  """

  # `calendar_id` and `calendar_path` are personal identifiers, not secrets:
  # Google calendar ids are email addresses and CalDAV paths can embed the
  # account username. Redacting by key keeps them out of structured logs;
  # `calendar_integration_id` (not matched) remains for correlation.
  @sensitive_substrings ~w(
    password
    passcode
    secret
    api_key
    apikey
    token
    authorization
    auth_header
    cookie
    private_key
    client_secret
    refresh_token
    access_token
    session_id
    calendar_id
    calendar_path
  )

  # Matched on the whole key or on a `_`-anchored suffix, never as a bare
  # substring: `attendee_email`, `organizer_email` and `new_email` all carry an
  # address, while `email_action`, `email_type` and `email_masked` do not, and
  # blanking those would cost diagnostics for no privacy gain.
  @sensitive_key_suffixes ~w(email)

  # Matched on the whole key only. `identifier` is the key the account-lockout
  # and rate-limiter paths use for an email address; `provider_identifier` is an
  # opaque calendar event id and stays readable.
  @sensitive_exact_keys ~w(identifier)

  @redacted "[REDACTED]"
  @filter_id :tymeslot_metadata_redactor

  @doc """
  Installs the redactor as a primary `:logger` filter.

  Idempotent — safe to call on application restart inside the same BEAM.
  """
  @spec attach() :: :ok
  def attach do
    _previous = :logger.remove_primary_filter(@filter_id)
    :ok = :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []})
  end

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(%{meta: meta} = event, _extra) when is_map(meta) do
    %{event | meta: redact_meta(meta)}
  end

  def filter(event, _extra), do: event

  defp redact_meta(meta) do
    if Enum.any?(meta, fn {k, _v} -> sensitive_key?(k) end) do
      Map.new(meta, fn {key, value} ->
        if sensitive_key?(key) do
          {key, @redacted}
        else
          {key, value}
        end
      end)
    else
      meta
    end
  end

  defp sensitive_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> sensitive_key?()
  end

  defp sensitive_key?(key) when is_binary(key) do
    downcased = String.downcase(key)

    Enum.any?(@sensitive_substrings, &String.contains?(downcased, &1)) or
      downcased in @sensitive_exact_keys or
      Enum.any?(@sensitive_key_suffixes, &suffix_match?(downcased, &1))
  end

  defp sensitive_key?(_other), do: false

  defp suffix_match?(key, suffix),
    do: key == suffix or String.ends_with?(key, "_" <> suffix)
end
