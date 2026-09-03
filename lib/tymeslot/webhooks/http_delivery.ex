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
  alias Tymeslot.Infrastructure.RedirectLocation
  alias Tymeslot.Security.ConnectionPinning
  alias Tymeslot.Webhooks.SsrfValidator

  @delivery_timeout_ms 10_000
  @max_redirects 5

  @type response :: {:ok, integer(), term()} | {:error, atom() | term()}

  @doc """
  POSTs `body` to `url` with the given `headers`, following up to
  #{@max_redirects} redirects. The initial URL and each redirect hop are
  SSRF-validated. 301/302/303 redirects switch to GET (RFC 9110 §15.4);
  307/308 preserve the original method and body.

  Every hop connects to the address its own check approved, rather than letting
  the HTTP client resolve the hostname again — see
  `Tymeslot.Security.ConnectionPinning`.

  Pass `skip_initial_check: true` when the caller has already validated `url`
  with `SsrfValidator` immediately before this call, to avoid resolving DNS
  for the same host twice; pass the addresses that check approved as
  `:pin_addresses` alongside it, or the saved resolution is exactly the one the
  connect would otherwise have to redo. Redirect hops are always re-validated
  regardless.
  """
  @spec post(String.t(), binary(), list() | map(), keyword()) :: response()
  def post(url, body, headers, opts \\ []) do
    if Keyword.get(opts, :skip_initial_check, false) do
      addresses = Keyword.get(opts, :pin_addresses, [])
      deliver_with_redirects(url, addresses, :post, body, headers, @max_redirects)
    else
      case SsrfValidator.check_pinned(url) do
        {:ok, addresses} ->
          deliver_with_redirects(url, addresses, :post, body, headers, @max_redirects)

        {:error, _reason} ->
          {:error, :blocked_by_ssrf}
      end
    end
  end

  # `redirects_remaining` is a budget of redirects still followable, so it is
  # exhausted at -1, not at 0: the hop entered with 0 left is the last one this
  # module is allowed to make. See the hop-accounting note in
  # `Tymeslot.Infrastructure.RedirectLocation`, which the ICS feed fetcher and
  # the video reachability probe follow too.
  defp deliver_with_redirects(_url, _addresses, _method, _body, _headers, redirects_remaining)
       when redirects_remaining < 0 do
    Logger.warning("Webhook delivery exceeded max redirects")
    {:error, :too_many_redirects}
  end

  defp deliver_with_redirects(url, addresses, method, body, headers, redirects_remaining) do
    case perform_http_request(url, addresses, method, body, headers) do
      {:ok, status, _body, response_headers} when status in 300..399 ->
        follow_redirect(url, method, body, headers, response_headers, redirects_remaining, status)

      {:ok, status, response_body, _headers} ->
        {:ok, status, response_body}

      {:error, _reason} = error ->
        error
    end
  end

  # 301/302/303 switch to GET and drop the body (RFC 9110 §15.4, matching what
  # browsers do); 307/308 preserve the original method and body.
  defp follow_redirect(from_url, method, body, headers, response_headers, hops_left, status) do
    with {:ok, next_url} <- RedirectLocation.next_url(response_headers, from_url),
         {:ok, next_addresses} <- SsrfValidator.check_pinned(next_url) do
      {next_method, next_body} = redirect_method(method, body, status)
      safe_headers = sanitise_headers_for_redirect(headers, from_url, next_url)

      deliver_with_redirects(
        next_url,
        next_addresses,
        next_method,
        next_body,
        safe_headers,
        hops_left - 1
      )
    else
      {:error, :missing_location} ->
        Logger.warning("Webhook redirect missing Location header", from_url: from_url)
        {:error, :redirect_missing_location}

      # Either an unfollowable Location (a non-HTTP scheme) or a hop the SSRF
      # re-check refused. Both are a redirect we will not chase.
      {:error, reason} ->
        Logger.warning("Webhook redirect blocked by SSRF protection",
          from_url: from_url,
          reason: reason
        )

        {:error, :blocked_redirect}
    end
  end

  defp redirect_method(_method, _body, status) when status in [301, 302, 303], do: {:get, nil}
  defp redirect_method(method, body, _status), do: {method, body}

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

  defp perform_http_request(url, addresses, :post, body, headers) do
    {pinned_url, opts} = pin(url, addresses)

    pinned_url
    |> Config.http_client_module().post(body, headers, opts)
    |> normalise_http_result()
  end

  defp perform_http_request(url, addresses, :get, _body, headers) do
    {pinned_url, opts} = pin(url, addresses)

    pinned_url
    |> Config.http_client_module().get(headers, opts)
    |> normalise_http_result()
  end

  defp pin(url, addresses) do
    ConnectionPinning.pin_request(url, addresses,
      receive_timeout: @delivery_timeout_ms,
      redirect: false
    )
  end

  defp normalise_http_result({:ok, response}) do
    {:ok, Map.get(response, :status), Map.get(response, :body), Map.get(response, :headers, %{})}
  end

  defp normalise_http_result({:error, %{reason: reason}}), do: {:error, reason}
  defp normalise_http_result({:error, reason}), do: {:error, reason}
end
