defmodule Tymeslot.Webhooks.HttpDelivery do
  @moduledoc """
  HTTP transport for webhook delivery with manual redirect following.

  Req's built-in redirect step is disabled so that each hop is independently
  re-validated by `Tymeslot.Webhooks.SsrfValidator` — a 3xx from a public
  host therefore cannot redirect the request to loopback or link-local
  ranges that the initial validation rejected. Sensitive request headers
  (`X-Tymeslot-Token`, `Authorization`) are stripped when a redirect crosses
  origins so they cannot leak to a third-party host.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Webhooks.SsrfValidator

  @delivery_timeout_ms 10_000
  @max_redirects 5

  @type response :: {:ok, integer(), term()} | {:error, atom() | term()}

  @doc """
  POSTs `body` to `url` with the given `headers`, following up to
  #{@max_redirects} redirects. The initial URL and each redirect hop are
  SSRF-validated. 301/302/303 redirects switch to GET (RFC 9110 §15.4);
  307/308 preserve the original method and body.
  """
  @spec post(String.t(), binary(), list() | map()) :: response()
  def post(url, body, headers) do
    case SsrfValidator.check(url) do
      :ok -> deliver_with_redirects(url, :post, body, headers, @max_redirects)
      {:error, _reason} -> {:error, :blocked_by_ssrf}
    end
  end

  defp deliver_with_redirects(_url, _method, _body, _headers, 0) do
    Logger.warning("Webhook delivery exceeded max redirects")
    {:error, :too_many_redirects}
  end

  defp deliver_with_redirects(url, method, body, headers, redirects_remaining) do
    case perform_http_request(url, method, body, headers) do
      {:ok, status, _body, response_headers} when status in 300..399 ->
        follow_redirect(url, method, body, headers, response_headers, redirects_remaining, status)

      {:ok, status, response_body, _headers} ->
        {:ok, status, response_body}

      {:error, _reason} = error ->
        error
    end
  end

  # 301/302/303: switch to GET and drop the body (browser-compatible redirect behaviour).
  defp follow_redirect(
         from_url,
         _method,
         _body,
         headers,
         response_headers,
         redirects_remaining,
         status
       )
       when status in [301, 302, 303] do
    with {:ok, next_url} <- extract_location(response_headers, from_url),
         :ok <- SsrfValidator.check(next_url) do
      safe_headers = sanitise_headers_for_redirect(headers, from_url, next_url)
      deliver_with_redirects(next_url, :get, nil, safe_headers, redirects_remaining - 1)
    else
      :error ->
        Logger.warning("Webhook redirect missing Location header", from_url: from_url)
        {:error, :redirect_missing_location}

      {:error, reason} ->
        Logger.warning("Webhook redirect blocked by SSRF protection",
          from_url: from_url,
          reason: reason
        )

        {:error, :blocked_redirect}
    end
  end

  # 307/308: preserve method and body as required by RFC 9110.
  defp follow_redirect(
         from_url,
         method,
         body,
         headers,
         response_headers,
         redirects_remaining,
         _status
       ) do
    with {:ok, next_url} <- extract_location(response_headers, from_url),
         :ok <- SsrfValidator.check(next_url) do
      safe_headers = sanitise_headers_for_redirect(headers, from_url, next_url)
      deliver_with_redirects(next_url, method, body, safe_headers, redirects_remaining - 1)
    else
      :error ->
        Logger.warning("Webhook redirect missing Location header", from_url: from_url)
        {:error, :redirect_missing_location}

      {:error, reason} ->
        Logger.warning("Webhook redirect blocked by SSRF protection",
          from_url: from_url,
          reason: reason
        )

        {:error, :blocked_redirect}
    end
  end

  defp sanitise_headers_for_redirect(headers, from_url, next_url) do
    if same_origin?(from_url, next_url) do
      headers
    else
      Enum.reject(headers, fn
        {"X-Tymeslot-Token", _value} -> true
        {"Authorization", _value} -> true
        _other -> false
      end)
    end
  end

  defp same_origin?(url_a, url_b) do
    a = URI.parse(url_a)
    b = URI.parse(url_b)

    a.scheme == b.scheme and
      String.downcase(a.host || "") == String.downcase(b.host || "") and
      normalise_port(a.scheme, a.port) == normalise_port(b.scheme, b.port)
  end

  defp normalise_port("https", nil), do: 443
  defp normalise_port("http", nil), do: 80
  defp normalise_port(_scheme, port), do: port

  defp extract_location(response_headers, from_url) do
    case location_value(response_headers) do
      nil ->
        :error

      raw_location ->
        {:ok, resolve_location(raw_location, from_url)}
    end
  end

  defp resolve_location(raw_location, from_url) do
    case URI.parse(raw_location) do
      %URI{scheme: scheme, host: host} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        URI.to_string(uri)

      %URI{scheme: nil, host: host} = uri
      when is_binary(host) and host != "" ->
        base_scheme = URI.parse(from_url).scheme || "https"
        URI.to_string(%{uri | scheme: base_scheme})

      _relative ->
        from_url |> URI.merge(raw_location) |> URI.to_string()
    end
  end

  defp location_value(headers) when is_map(headers) do
    case Map.get(headers, "location") do
      [value | _rest] when is_binary(value) -> value
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp location_value(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) or is_atom(key) ->
        if String.downcase(to_string(key)) == "location", do: to_string(value)

      _other ->
        nil
    end)
  end

  defp location_value(_headers), do: nil

  defp perform_http_request(url, :post, body, headers) do
    result =
      Config.http_client_module().post(url, body, headers,
        receive_timeout: @delivery_timeout_ms,
        redirect: false
      )

    normalise_http_result(result)
  end

  defp perform_http_request(url, :get, _body, headers) do
    result =
      Config.http_client_module().get(url, headers,
        receive_timeout: @delivery_timeout_ms,
        redirect: false
      )

    normalise_http_result(result)
  end

  defp normalise_http_result({:ok, response}) do
    {:ok, Map.get(response, :status), Map.get(response, :body), Map.get(response, :headers, %{})}
  end

  defp normalise_http_result({:error, %{reason: reason}}), do: {:error, reason}
  defp normalise_http_result({:error, reason}), do: {:error, reason}
end
