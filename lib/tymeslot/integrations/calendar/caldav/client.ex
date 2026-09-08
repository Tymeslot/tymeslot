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
    # Carried on the client but never applied: nothing below this module
    # builds a TLS option from it, so CalDAV always verifies. See the field
    # comment on `CalendarIntegrationSchema` before changing it.
    verify_ssl: true
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          provider: atom(),
          calendar_paths: [String.t()],
          verify_ssl: boolean()
        }
end
