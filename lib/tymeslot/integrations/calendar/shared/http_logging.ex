defmodule Tymeslot.Integrations.Calendar.Shared.HttpLogging do
  @moduledoc """
  Redaction helpers shared by the calendar transports' log lines.

  A URL on these paths is one the user typed or one a server handed back, and
  either can carry credentials in its userinfo; a response body on them is
  mailbox content. Both are reduced here rather than in each transport, because
  a hardening fix applied to one copy of a redaction helper silently misses the
  other, and the copy that missed it is the one that leaks.
  """

  # Enough of an unmodelled error body to carry the server's explanation (they
  # answer 4xx with a short XML or plain-text sentence) without pouring a whole
  # response into the logs.
  @body_excerpt_chars 500

  @doc """
  Reduces a URL to what a log line may carry.

  Scheme and host by default; `include_path: true` keeps the path as well, for
  transports where the path names the resource that failed and no credential
  can reach it. Anything else the URL carried, userinfo above all, is dropped
  by rebuilding the string from the parts rather than by editing it.

  A URL with no scheme or no host, which is what a hostname typed into a
  configuration field parses as, yields `"(unparseable url)"`. `URI.parse/1`
  does not raise, so this is a fallback rather than a guard: the error paths
  that call it must not themselves fail over a malformed URL.
  """
  @spec loggable_url(String.t(), keyword()) :: String.t()
  def loggable_url(url, opts \\ []) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        origin = "#{scheme}://#{host}"

        if Keyword.get(opts, :include_path, false),
          do: origin <> to_string(uri.path),
          else: origin

      _unparseable ->
        "(unparseable url)"
    end
  end

  @doc """
  The first #{@body_excerpt_chars} characters of a response body, whitespace
  collapsed, for the log line of a status the caller does not model.

  A body that is not valid text is reported as such rather than rendered: a
  binary attachment or a truncated multi-byte sequence would otherwise reach
  the log as bytes.
  """
  @spec body_excerpt(term()) :: String.t()
  def body_excerpt(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> String.slice(0, @body_excerpt_chars)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    else
      "(non-text body)"
    end
  end

  def body_excerpt(_other), do: ""
end
