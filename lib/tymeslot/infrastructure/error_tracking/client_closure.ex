defmodule Tymeslot.Infrastructure.ErrorTracking.ClientClosure do
  @moduledoc """
  Recognises a request whose client went away before the response was sent:
  the visitor closed the tab or navigated on while a large static file (the
  background video of the sign-in pages) was still being written.

  Bandit raises `Bandit.TransportError` for it while the endpoint is still
  serving the request, so ErrorTracker's Plug integration records it as a
  server error, although nothing failed on this side. Bandit itself treats
  these closures as routine and does not log them unless asked to
  (`log_client_closures`). They are neither stored nor alerted on
  (`Tymeslot.Infrastructure.ErrorTracking.Ignorer`).

  The rule reads only what ErrorTracker keeps of the exception, its kind and
  message, plus the context, and requires all three:

    * the kind is `Bandit.TransportError`;
    * the message is one Bandit raises when the client closed the
      connection: `"Unrecoverable error: <reason>"` over HTTP/1, for the
      reasons Bandit counts as a client closure (`Bandit.Logger`), or
      `"Client reset stream normally"` over HTTP/2;
    * it arose serving a request or a LiveView
      (`Tymeslot.Infrastructure.ErrorTracking.ClientError.request_origin?/1`).

  Any other transport failure, such as a TLS or protocol error, is recorded
  as usual.

  Every function here is total, since its caller runs in telemetry handlers:
  anything unexpected answers `false`, which means "record it".
  """

  alias Tymeslot.Infrastructure.ErrorTracking.ClientError

  @transport_error "Elixir.Bandit.TransportError"

  # Bandit.Logger's @client_closure_errors: the posix reasons a socket
  # reports once the peer is gone.
  @closed_messages ~w(closed enotconn einval econnaborted econnreset)
                   |> Enum.map(&"Unrecoverable error: #{&1}")
                   |> Enum.concat(["Client reset stream normally"])

  @doc """
  Returns true for an exception, known as ErrorTracker records it (`kind` is
  the exception module's name, `reason` its message), that says the client
  closed the connection while a request was being served, as shown by
  `context`.
  """
  @spec error?(String.t(), String.t(), map()) :: boolean()
  def error?(@transport_error, reason, context) when reason in @closed_messages,
    do: ClientError.request_origin?(context)

  def error?(_kind, _reason, _context), do: false
end
