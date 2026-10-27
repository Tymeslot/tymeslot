defmodule Tymeslot.Security.Security do
  @moduledoc """
  Additional security utilities for Tymeslot.
  Provides protection against common attack vectors.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.FieldValidators.TLDList

  @doc """
  Validates a list of domain names, filtering empty entries first.
  Returns `{:ok, validated_domains}` if all non-empty entries are valid,
  or `{:error, messages}` otherwise: each distinct problem once, as its own
  translated message, in the order the entries were given.
  """
  @spec validate_domains([String.t()]) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def validate_domains(domains) when is_list(domains) do
    filtered = Enum.reject(domains, &(&1 == "" or is_nil(&1)))
    results = Enum.map(filtered, &validate_domain/1)
    {oks, errors} = Enum.split_with(results, &match?({:ok, _domain}, &1))

    if errors == [] do
      {:ok, Enum.map(oks, fn {:ok, d} -> d end)}
    else
      # Each distinct problem once, as its own translated message: joining
      # them is the presentation's job, in the reader's language.
      {:error, errors |> Enum.map(fn {:error, reason} -> reason end) |> Enum.uniq()}
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
        {:error, dgettext("errors", "Some domains exceed maximum length (max 255 characters)")}

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
          {:error, dgettext("errors", "Invalid domain format (e.g. *.example.com)")}
        end

      # Domain pattern: alphanumeric, dots, and hyphens. Must not start/end with hyphen/dot.
      # No protocol (http://), no path (/path), no port (:8080).
      Regex.match?(
        ~r/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$/i,
        domain
      ) ->
        validate_domain_tld(String.downcase(domain))

      true ->
        {:error, dgettext("errors", "Invalid domain format (e.g. example.com)")}
    end
  end

  def validate_domain(_invalid_value), do: {:error, dgettext("errors", "Invalid domain")}

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
