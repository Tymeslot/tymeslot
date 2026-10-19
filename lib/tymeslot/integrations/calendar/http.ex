defmodule Tymeslot.Integrations.Calendar.HTTP do
  @moduledoc """
  Shared helpers for making authenticated HTTP requests to calendar providers.

  Handles Authorization header injection, optional query params, JSON encoding,
  and delegates response handling to the caller for provider-specific behaviour.
  """

  alias Tymeslot.Infrastructure.Config

  @doc """
  Human-readable detail for a provider 404, derived from the request path.

  Google and Outlook both answer a missing calendar and a missing event with a
  bare 404, so only the path tells them apart. Event-scoped paths end in an
  event id (`…/events/<id>`); Google's `…/events/watch` is the push-channel
  subscription endpoint and is calendar-scoped, as is a request against the
  event collection itself (`…/events`).
  """
  @spec not_found_message(String.t()) :: String.t()
  def not_found_message(path) do
    case path |> String.split("/") |> Enum.take(-2) do
      ["events", id] when id != "watch" -> "Event not found"
      _calendar_scoped -> "Calendar not found"
    end
  end

  @doc """
  Percent-encodes a provider-supplied id (a calendar, event or subscription id)
  for use as one segment of a request path.

  Every character outside the unreserved set is encoded, `#`, `/` and `?`
  among them. Google's holiday calendar ids carry a `#`
  (`en.uk#holiday@group.v.calendar.google.com`), which interpolated as it is
  would end the path and send the request to another calendar.
  """
  @spec segment(String.t()) :: String.t()
  def segment(id) when is_binary(id), do: URI.encode(id, &URI.char_unreserved?/1)

  # Bounds a best-effort request to stop provider push notifications (a
  # Google channel stop, a Graph subscription delete): nothing waits on its
  # outcome, and on disconnect it runs while the owner waits on the click.
  # `request_timeout` caps the whole response, not each chunk of it.
  @push_stop_http_options [pool_timeout: 1_000, receive_timeout: 5_000, request_timeout: 5_000]

  @doc """
  HTTP client options for a request that stops provider push notifications,
  passed as `http_options:` to `request/5` or `request_with_body/6`.
  """
  @spec push_stop_http_options() :: keyword()
  def push_stop_http_options, do: @push_stop_http_options

  @spec request(atom() | String.t(), String.t(), String.t(), String.t(), keyword()) :: any()
  def request(method, base_url, path, token, opts \\ []) do
    case normalize_method(method) do
      {:ok, normalized_method} ->
        do_request(normalized_method, base_url, path, token, "", opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec request_with_body(
          atom() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          any(),
          keyword()
        ) ::
          any()
  def request_with_body(method, base_url, path, token, body, opts) do
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
      _other -> {:error, %RuntimeError{message: "Invalid method: #{method}"}}
    end
  end

  defp normalize_method(method), do: {:error, %RuntimeError{message: "Invalid method: #{method}"}}

  defp do_request(method, base_url, path, token, body, opts) do
    params = Keyword.get(opts, :params, %{})
    headers = prepend_auth_header(Keyword.get(opts, :headers, []), token)
    http_options = Keyword.get(opts, :http_options, [])
    request_fun = Keyword.get(opts, :request_fun, &default_request(&1, &2, &3, &4, http_options))
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
    |> Enum.reject(fn {k, _value} -> String.downcase(k) == "authorization" end)
    |> List.insert_at(0, auth_header)
  end

  defp default_request(method, url, body, headers, http_options) do
    Config.http_client_module().request(method, url, body, headers, http_options)
  end
end
