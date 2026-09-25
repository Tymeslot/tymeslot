defmodule Tymeslot.Integrations.Common.OAuth.LogContext do
  @moduledoc """
  The allowed-key filter for caller-supplied OAuth token log context.

  Both shared token modules (`TokenExchange` and `TokenFlow`) merge a caller's
  `:log_context` into their failure log lines, and both need the same guarantee:
  a caller cannot widen the line, and cannot leak a credential by naming a key
  nobody vetted. The list lives here so there is exactly one of it; a second
  copy is a second thing to forget when a new provider is added.

  Pass scalar ids, never the config map or the integration struct. Every caller
  on these paths holds decrypted OAuth credentials at the moment it logs, which
  is also why the response body is redacted at the same call sites.
  """

  # Deliberately narrow: enough to attribute a failure to an integration, and
  # nothing that could carry a credential.
  @allowed_keys [:integration_id, :user_id, :provider]

  @doc """
  Keeps only the allowed keys, dropping nils.

  Nils are dropped so a caller holding only part of the context (a transient
  config built for a connection probe, say) does not emit `integration_id: nil`.
  """
  @spec filter(keyword()) :: keyword()
  def filter(log_context) when is_list(log_context) do
    Enum.filter(log_context, fn {key, value} -> key in @allowed_keys and not is_nil(value) end)
  end

  @doc """
  Reads a caller's `:log_context` out of an options list and filters it.
  """
  @spec from_opts(keyword()) :: keyword()
  def from_opts(opts) do
    opts |> Keyword.get(:log_context, []) |> filter()
  end
end
