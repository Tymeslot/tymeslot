defmodule Tymeslot.Integrations.Calendar.CalDAV.ConflictResolution do
  @moduledoc """
  Policy for resolving `412 Precondition Failed` responses to CalDAV writes.

  A 412 from a conditional PUT means the server's ETag no longer matches the
  one we sent via `If-Match` — someone else (or another device) has updated
  the event since we last saw it. How to recover from this is a decision the
  caller must make; this module gives it a name.

    * `:fail`        — surface the conflict to the caller as
                       `{:error, :precondition_failed}`. The local change is
                       not retried; the caller is expected to re-read the
                       server version, decide what to do, and try again.
                       Safe default — matches the pre-existing behaviour.

    * `:keep_server` — silently treat the conflict as success and return
                       `:ok`. The next sync will pull the server version
                       into the local cache. Use when the server is
                       authoritative and the local change was optional.

    * `:keep_local`  — retry the write without `If-Match`, forcing the local
                       version to overwrite the server's. Use only when
                       Tymeslot owns the event and the server copy is
                       expected to be stale (e.g. events with a
                       `@tymeslot.com` UID suffix).

  The default is `:fail` — any caller that wants a different policy must
  opt in explicitly via the `:conflict_resolution` option.
  """

  @type t :: :fail | :keep_server | :keep_local

  @spec default() :: t()
  def default, do: :fail

  @spec valid?(term()) :: boolean()
  def valid?(policy) when policy in [:fail, :keep_server, :keep_local], do: true
  def valid?(_other), do: false
end
