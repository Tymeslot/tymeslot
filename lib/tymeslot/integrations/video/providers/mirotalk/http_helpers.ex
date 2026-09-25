defmodule Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpers do
  @moduledoc false

  require Logger

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Security.SsrfBlockedError
  alias Tymeslot.Security.SsrfGuard

  @doc """
  Attempts an HTTPS request first; falls back to the original base URL on
  connection errors.

  `fun` receives the fully-built URL and must return
  `{:ok, %Req.Response{}}` or `{:error, reason}`.

  An `%SsrfBlockedError{}` is terminal: the fallback is skipped, because the
  host is blocked regardless of scheme.

  The fallback re-sends the request on whatever scheme `base_url` carries,
  which for a plain-http server means the API key travels in the clear, so it
  runs only where the operator has opted into private addresses for video.
  That switch is how a deployment declares its MiroTalk is on its own network;
  everywhere else an unreachable HTTPS endpoint is reported as the error it
  is, rather than being retried in a form that would leak the credential to
  anyone on the path.
  """
  @spec try_https_then_http(String.t(), String.t(), (String.t() ->
                                                       {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def try_https_then_http(base_url, path, fun) when is_binary(base_url) and is_binary(path) do
    https_url = force_https(base_url) <> path

    case fun.(https_url) do
      {:ok, %Req.Response{} = resp} ->
        {:ok, resp}

      {:error, %SsrfBlockedError{} = blocked} ->
        {:error, blocked}

      {:error, exception} when is_exception(exception) ->
        maybe_retry_on_base_scheme(base_url, path, fun, exception)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def try_https_then_http(base_url, path, fun) do
    fun.(base_url <> path)
  end

  defp maybe_retry_on_base_scheme(base_url, path, fun, exception) do
    if SsrfGuard.allow_private_for_video?() do
      case fun.(base_url <> path) do
        {:ok, %Req.Response{} = resp} -> {:ok, resp}
        {:error, reason} -> {:error, reason}
      end
    else
      Logger.warning(
        "MiroTalk server did not answer over HTTPS and the cleartext retry is " <>
          "not available, because private addresses are not allowed for video",
        server: HTTPClient.log_safe_origin(base_url)
      )

      {:error, exception}
    end
  end

  @doc """
  Rewrites a URL to use the HTTPS scheme on port 443.
  """
  @spec force_https(String.t()) :: String.t()
  def force_https(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.put(:scheme, "https")
    |> Map.put(:port, 443)
    |> URI.to_string()
  end
end
