defmodule Tymeslot.Integrations.Calendar.HTTP do
  @moduledoc """
  Shared helpers for making authenticated HTTP requests to calendar providers.

  Handles Authorization header injection, optional query params, JSON encoding,
  and delegates response handling to the caller for provider-specific behaviour.
  """

  alias Tymeslot.Infrastructure.HTTPClient

  @spec request(atom() | String.t(), String.t(), String.t(), String.t(), keyword()) :: any()
  def request(method, base_url, path, token, opts \\ []) do
    case normalize_method(method) do
      {:ok, normalized_method} ->
        do_request(normalized_method, base_url, path, token, "", opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec request_with_body(atom() | String.t(), String.t(), String.t(), String.t(), any(), keyword()) ::
          any()
  def request_with_body(method, base_url, path, token, body, opts \\ []) do
    case normalize_method(method) do
      {:ok, normalized_method} ->
        encoder = Keyword.get(opts, :encoder, &Jason.encode!/1)
        skip_encoding? = Keyword.get(opts, :skip_encoding?, false)
        encoded_body = if skip_encoding?, do: body, else: encoder.(body)

        headers = Keyword.get(opts, :headers, [{"Content-Type", "application/json"}])

        do_request(
          normalized_method,
          base_url,
          path,
          token,
          encoded_body,
          Keyword.put(opts, :headers, headers)
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_method(method) when is_atom(method), do: {:ok, method}

  defp normalize_method(method) when is_binary(method) do
    case String.downcase(method) do
      "get" -> {:ok, :get}
      "post" -> {:ok, :post}
      "put" -> {:ok, :put}
      "patch" -> {:ok, :patch}
      "delete" -> {:ok, :delete}
      "head" -> {:ok, :head}
      "options" -> {:ok, :options}
      "report" -> {:ok, :report}
      _ -> {:error, %HTTPoison.Error{reason: {:invalid_method, method}}}
    end
  end

  defp normalize_method(method), do: {:error, %HTTPoison.Error{reason: {:invalid_method, method}}}

  defp do_request(method, base_url, path, token, body, opts) do
    params = Keyword.get(opts, :params, %{})
    headers = prepend_auth_header(Keyword.get(opts, :headers, []), token)
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)
    response_handler = Keyword.get(opts, :response_handler, &Function.identity/1)
    final_url = build_url(base_url, path, params)

    response_handler.(request_fun.(method, final_url, body, headers))
  end

  defp build_url(base, path, params) do
    url = base <> path

    if params == %{} do
      url
    else
      url <> "?" <> URI.encode_query(params)
    end
  end

  defp prepend_auth_header(headers, token) do
    auth_header = {"Authorization", "Bearer #{token}"}

    headers
    |> Enum.reject(fn {k, _} -> String.downcase(k) == "authorization" end)
    |> List.insert_at(0, auth_header)
  end

  defp default_request(method, url, body, headers) do
    HTTPClient.request(method, url, body, headers)
  end
end
