defmodule Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpers do
  @moduledoc false

  @doc """
  Attempts an HTTPS request first; falls back to the original base URL on
  connection errors.

  `fun` receives the fully-built URL and must return
  `{:ok, %Req.Response{}}` or `{:error, reason}`.
  """
  @spec try_https_then_http(String.t(), String.t(), (String.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def try_https_then_http(base_url, path, fun) when is_binary(base_url) and is_binary(path) do
    https_url = force_https(base_url) <> path

    case fun.(https_url) do
      {:ok, %Req.Response{} = resp} ->
        {:ok, resp}

      {:error, exception} when is_exception(exception) ->
        fallback_url = base_url <> path

        case fun.(fallback_url) do
          {:ok, %Req.Response{} = resp2} -> {:ok, resp2}
          {:error, exception2} when is_exception(exception2) -> {:error, exception2}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def try_https_then_http(base_url, path, fun) do
    fun.(base_url <> path)
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
