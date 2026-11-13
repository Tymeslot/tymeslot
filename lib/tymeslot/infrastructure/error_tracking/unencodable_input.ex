defmodule Tymeslot.Infrastructure.ErrorTracking.UnencodableInput do
  @moduledoc """
  Recognises a query PostgreSQL refused because a value sent by a visitor
  holds a character its encoding cannot store: a null byte, which is valid
  UTF-8 but not valid in a PostgreSQL string.

  Postgrex raises `Postgrex.Error` for it, and `Plug.Exception.status/1`
  answers 400 for that code, so the visitor gets the right response. The
  status exists only at runtime, read from the exception's `postgres.code`,
  so `Tymeslot.Infrastructure.ErrorTracking.ClientError`, which judges an
  exception by its default struct, sees a 500. This rule fills that gap.
  Boundaries strip null bytes where they can; this covers any body parameter
  that reaches a query without passing one.

  The rule reads only what ErrorTracker keeps of the exception, its kind and
  message, plus the context, and requires all three:

    * the kind is `Postgrex.Error`;
    * the message carries the `character_not_in_repertoire` code, as
      `Postgrex.Error.message/1` writes it (`"ERROR 22021
      (character_not_in_repertoire) ..."`);
    * it arose serving a request or a LiveView
      (`Tymeslot.Infrastructure.ErrorTracking.ClientError.request_origin?/1`).

  `Postgrex.Error` is never ignored by kind alone: real database faults share
  it and must keep alerting. The origin rule stays too, since a null byte
  reaching a query in a job means a bug in what was stored or enqueued.

  Every function here is total, since its caller runs in telemetry handlers:
  anything unexpected answers `false`, which means "record it".
  """

  alias Tymeslot.Infrastructure.ErrorTracking.ClientError

  @postgrex_error "Elixir.Postgrex.Error"
  @unencodable ~r/\A\w+ 22021 \(character_not_in_repertoire\)/

  @doc """
  Returns true for an exception, known as ErrorTracker records it (`kind` is
  the exception module's name, `reason` its message), that says PostgreSQL
  could not encode a value while a request was being served, as shown by
  `context`.
  """
  @spec error?(String.t(), String.t(), map()) :: boolean()
  def error?(@postgrex_error, reason, context) when is_binary(reason),
    do: reason =~ @unencodable and ClientError.request_origin?(context)

  def error?(_kind, _reason, _context), do: false
end
