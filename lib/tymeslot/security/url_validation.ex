defmodule Tymeslot.Security.UrlValidation do
  @moduledoc """
  Shared HTTP/HTTPS URL validation helpers for security-sensitive inputs.
  """

  @default_invalid_message "Must be a valid HTTP or HTTPS URL (e.g., https://example.com)"
  @default_length_error "URL must be 2000 characters or less"
  @default_scheme_error "Only HTTP and HTTPS URLs are allowed"
  @default_https_error "Use HTTPS for non-local servers"
  @disallowed_protocols ["javascript:", "data:", "file:", "ftp:"]

  @spec validate_http_url(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_http_url(url, opts \\ [])

  def validate_http_url(url, opts) when is_binary(url) do
    invalid_message = Keyword.get(opts, :invalid_message, @default_invalid_message)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        validate_url_checks(url, scheme, host, opts)

      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        disallowed_protocol_error =
          Keyword.get(opts, :disallowed_protocol_error, @default_scheme_error)

        {:error, disallowed_protocol_error}

      _ ->
        {:error, invalid_message}
    end
  end

  def validate_http_url(_url, _opts), do: {:error, @default_invalid_message}

  defp validate_url_checks(url, scheme, host, opts) do
    length_error = Keyword.get(opts, :length_error_message, @default_length_error)

    disallowed_protocol_error =
      Keyword.get(opts, :disallowed_protocol_error, @default_scheme_error)

    https_error_message = Keyword.get(opts, :https_error_message, @default_https_error)
    max_length = Keyword.get(opts, :max_length, 2_000)
    disallowed_protocols = Keyword.get(opts, :disallowed_protocols, @disallowed_protocols)
    enforce_https_for_public = Keyword.get(opts, :enforce_https_for_public, false)
    extra_checks = Keyword.get(opts, :extra_checks)

    cond do
      String.length(url) > max_length ->
        {:error, length_error}

      contains_disallowed_substring?(url, disallowed_protocols) ->
        {:error, disallowed_protocol_error}

      enforce_https_for_public and scheme == "http" and not local_or_private_host?(host) ->
        {:error, https_error_message}

      true ->
        run_extra_checks(extra_checks, %{url: url, scheme: scheme, host: host})
    end
  end

  defp contains_disallowed_substring?(url, disallowed_protocols) do
    Enum.any?(disallowed_protocols, &String.contains?(url, &1))
  end

  defp run_extra_checks(nil, _context), do: :ok

  defp run_extra_checks(fun, context) when is_function(fun, 1), do: fun.(context)

  defp local_or_private_host?(host) do
    host == "localhost" or
      String.starts_with?(host, [
        "127.",
        "10.",
        "192.168.",
        "172.16.",
        "172.17.",
        "172.18.",
        "172.19.",
        "172.20.",
        "172.21.",
        "172.22.",
        "172.23.",
        "172.24.",
        "172.25.",
        "172.26.",
        "172.27.",
        "172.28.",
        "172.29.",
        "172.30.",
        "172.31."
      ])
  end
end
