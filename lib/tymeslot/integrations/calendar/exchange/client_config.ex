defmodule Tymeslot.Integrations.Calendar.Exchange.ClientConfig do
  @moduledoc """
  The connected Exchange client every EWS operation is issued with.

  A struct rather than a plain map for one reason: it carries the
  integration's decrypted password, and only a struct can refuse to print it.
  `@derive {Inspect, except: [:password]}` masks the field wherever the config
  is inspected — an exception message, a `dbg/1`, an OTP crash report that
  prints a task's arguments — which is what a plain map cannot do however
  carefully the schema that produced the value marked it `redact: true`. It is
  the same conversion `Tymeslot.Integrations.Calendar.CalDAV.Client` is for the
  CalDAV family.

  Build one through `new/1`; nothing else should construct one. That single
  funnel is what makes the redaction hold, so `new/1` raises on a key this
  struct does not declare rather than dropping it: the field set is closed,
  and a caller inventing a key needs to say so here first.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @derive {Inspect, except: [:password]}
  defstruct [
    :base_url,
    :username,
    :password,
    # The schema's `provider` column, so a string ("exchange"), not an atom.
    :provider,
    :provider_account_email,
    # Which integration the availability read caches under. Absent on the
    # connection-test and discovery configs, which have no persisted row yet.
    :calendar_integration_id,
    # The folder a read is scoped to, and the folder a booking is written to.
    # `:calendar` is EWS's distinguished id for the mailbox's default calendar.
    :calendar_id,
    :booking_folder_id,
    # Left nil rather than defaulted here: `Exchange.Client` owns the timeout
    # and falls back to its own `@default_timeout`, so there is one value to
    # change and it is next to the reasoning for it.
    :request_timeout,
    # Carried because `CalendarIntegrationSchema.to_provider_config/1` is
    # shaped for the CalDAV family and always sets it. An EWS folder is named
    # by an opaque `FolderId`, never a path, so nothing here reads it.
    calendar_paths: [],
    verify_ssl: true
  ]

  @type folder_id :: String.t() | :calendar

  @type t :: %__MODULE__{
          base_url: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          provider: String.t() | nil,
          provider_account_email: String.t() | nil,
          calendar_integration_id: integer() | nil,
          calendar_id: folder_id() | nil,
          booking_folder_id: folder_id() | nil,
          request_timeout: pos_integer() | nil,
          calendar_paths: [String.t()],
          verify_ssl: boolean()
        }

  @doc """
  Builds a config from a persisted integration or an atom-keyed map.

  An existing config passes back unchanged, so a client handed to a provider
  callback a second time is not rebuilt.

  Raises `KeyError` on a key this struct does not declare. That is deliberate:
  `struct/2` would drop it in silence and the behaviour it controlled would
  revert to a default with nothing in the logs, which is a far worse failure
  than a crash naming the key.
  """
  @spec new(t() | CalendarIntegrationSchema.t() | %{atom() => term()}) :: t()
  def new(%__MODULE__{} = config), do: config

  # Credentials live encrypted on the schema; `decrypt_credentials/1` populates
  # the virtual fields that `to_provider_config/1` then reads. Reading
  # `integration.username` directly would yield nil on a freshly loaded row, so
  # both steps are required and neither is optional.
  #
  # Two fields are merged back on top because `to_provider_config/1` is shaped
  # for the CalDAV family and deliberately carries neither: `verify_ssl`, which
  # an on-premises server with a self-signed certificate needs, and
  # `provider_account_email`, without which the availability read has no
  # mailbox to address. It is stored in plaintext, so it survives untouched.
  def new(%CalendarIntegrationSchema{} = integration) do
    integration
    |> CalendarIntegrationSchema.decrypt_credentials()
    |> CalendarIntegrationSchema.to_provider_config()
    |> Map.merge(%{
      verify_ssl: integration.verify_ssl,
      provider_account_email: integration.provider_account_email
    })
    |> new()
  end

  # The connection-test and discovery paths build one from form input before
  # any row exists.
  def new(config) when is_map(config), do: struct!(__MODULE__, config)
end
