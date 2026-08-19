defmodule Tymeslot.Security.Security do
  @moduledoc """
  Additional security utilities for Tymeslot.
  Provides protection against common attack vectors.
  """

  require Logger

  alias Tymeslot.Security.FieldValidators.TLDList
  alias Tymeslot.Timezones

  # Longest IANA id is well under 40 chars; this is an injection guard, not a
  # format check, so it stays generous.
  @max_timezone_length 100

  @doc """
  Sanitizes timezone input to prevent injection.

  Identity is decided by `Timezones.valid?/1`, a real IANA lookup, so anything
  the time zone database resolves is accepted. A prior format regex rejected
  legitimate zones the picker itself offers — three-segment ids such as
  `America/Argentina/Buenos_Aires` and offset zones such as `Etc/GMT+5` — which
  silently discarded the user's choice.

  The length guard runs first so an oversized string is rejected before it
  reaches the lookup.
  """
  @spec validate_timezone(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_timezone(timezone) when is_binary(timezone) do
    cond do
      String.length(timezone) > @max_timezone_length ->
        Logger.warning("Timezone validation failed: too long",
          timezone_length: String.length(timezone)
        )

        {:error, "Timezone too long"}

      not Timezones.valid?(timezone) ->
        Logger.warning("Timezone validation failed: unknown zone", timezone: timezone)
        {:error, "Unknown timezone"}

      true ->
        {:ok, timezone}
    end
  end

  @spec validate_timezone(term()) :: {:error, String.t()}
  def validate_timezone(timezone) do
    Logger.warning("Timezone validation failed: not a string", value_type: inspect(timezone))
    {:error, "Invalid timezone"}
  end

  @doc """
  Validates a list of domain names, filtering empty entries first.
  Returns `{:ok, validated_domains}` if all non-empty entries are valid,
  or `{:error, error_message}` with aggregated error reasons otherwise.
  """
  @spec validate_domains([String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate_domains(domains) when is_list(domains) do
    filtered = Enum.reject(domains, &(&1 == "" or is_nil(&1)))
    results = Enum.map(filtered, &validate_domain/1)
    {oks, errors} = Enum.split_with(results, &match?({:ok, _domain}, &1))

    if errors == [] do
      {:ok, Enum.map(oks, fn {:ok, d} -> d end)}
    else
      error_msg =
        errors
        |> Enum.map(fn {:error, reason} -> reason end)
        |> Enum.uniq()
        |> Enum.join(", ")

      {:error, error_msg}
    end
  end

  @doc """
  Validates a domain name to ensure it's a valid host without protocol or path.
  Accepts standard domains and localhost for development.
  """
  @spec validate_domain(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_domain(domain) when is_binary(domain) do
    domain =
      domain
      |> String.trim()
      |> maybe_extract_host()

    cond do
      domain in ["localhost", "127.0.0.1", "::1"] ->
        {:ok, domain}

      domain == "none" ->
        {:ok, "none"}

      String.length(domain) > 255 ->
        {:error, "Some domains exceed maximum length (max 255 characters)"}

      # Wildcard subdomain pattern: *.example.com
      String.starts_with?(domain, "*.") ->
        bare = String.slice(domain, 2, String.length(domain) - 2)

        if Regex.match?(
             ~r/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$/i,
             bare
           ) do
          case validate_domain_tld(String.downcase(bare)) do
            {:ok, validated} -> {:ok, "*." <> validated}
            error -> error
          end
        else
          {:error, "Invalid domain format (e.g. *.example.com)"}
        end

      # Domain pattern: alphanumeric, dots, and hyphens. Must not start/end with hyphen/dot.
      # No protocol (http://), no path (/path), no port (:8080).
      Regex.match?(
        ~r/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$/i,
        domain
      ) ->
        validate_domain_tld(String.downcase(domain))

      true ->
        {:error, "Invalid domain format (e.g. example.com)"}
    end
  end

  def validate_domain(_invalid_value), do: {:error, "Invalid domain"}

  defp validate_domain_tld(domain) do
    tld = TLDList.extract_tld(domain)

    case TLDList.validate_tld(tld, "Domain") do
      :ok -> {:ok, domain}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_extract_host(domain) do
    if String.contains?(domain, "://") do
      case URI.parse(domain) do
        %URI{host: host} when is_binary(host) -> host
        _uri -> domain
      end
    else
      domain
    end
  end
end
