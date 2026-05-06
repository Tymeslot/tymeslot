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
  """

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
  )

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

  @doc """
  Returns the list of substrings that mark a metadata key as sensitive.

  Exposed for tests.
  """
  @spec sensitive_substrings() :: [String.t()]
  def sensitive_substrings, do: @sensitive_substrings

  defp redact_meta(meta) do
    if Enum.any?(meta, fn {k, _} -> sensitive_key?(k) end) do
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
    Enum.any?(@sensitive_substrings, &String.contains?(downcased, &1))
  end

  defp sensitive_key?(_other), do: false
end
