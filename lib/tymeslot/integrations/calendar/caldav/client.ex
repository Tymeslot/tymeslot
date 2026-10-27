defmodule Tymeslot.Integrations.Calendar.CalDAV.Client do
  @moduledoc """
  The connected CalDAV client every CalDAV-family provider hands to
  `Base.*` and `Http.*`.

  A struct rather than a plain map for one reason: it carries the
  integration's decrypted password, and only a struct can refuse to print it.
  `@derive {Inspect, except: [:password]}` masks the field wherever the client
  is inspected — an exception message, a `dbg/1`, an OTP crash report that
  prints a task's arguments — which is what a plain map cannot do however
  carefully the schema that produced the value marked it `redact: true`.

  Build one through `Providers.CaldavCommon.build_client/2`; nothing else
  should construct it directly.
  """

  @derive {Inspect, except: [:password]}
  defstruct [
    :base_url,
    :username,
    :password,
    :provider,
    calendar_paths: [],
    # Every collection on the integration a write is allowed to target, which
    # is not the same as the one this client defaults to. A booking client
    # addresses one collection, but the calendar grid lets the organiser pick
    # another, and `CaldavCommon.create_event/2` needs a list to check that
    # choice against: a `calendar_id` off the event payload is caller-supplied
    # and must never be able to send a write to an arbitrary path.
    writable_calendar_paths: [],
    # Collections shared with the account as busy times only, read through
    # the free-busy-query REPORT rather than calendar-query (`CalDAV.FreeBusy`).
    free_busy_paths: [],
    # Set only for a discovery a person asked for (validating a connection,
    # reconnecting it): it has to reach a server whose host breaker its
    # earlier failures opened, since that is how the breaker gets closed.
    # Those paths are rate-limited per user already.
    skip_breaker: false
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          provider: atom(),
          calendar_paths: [String.t()],
          writable_calendar_paths: [String.t()],
          free_busy_paths: [String.t()],
          skip_breaker: boolean()
        }
end
