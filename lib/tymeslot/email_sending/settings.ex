defmodule Tymeslot.EmailSending.Settings do
  @moduledoc """
  The public SMTP settings view. Neither plaintext nor encrypted credentials
  leave the domain through ordinary settings reads.
  """

  alias Tymeslot.EmailSending.UserSmtpSettingsSchema

  @type t :: %__MODULE__{}
  @type version :: {pos_integer(), pos_integer()}
  defstruct [
    :id,
    :host,
    :port,
    :security,
    :from_address,
    :from_name,
    :revision,
    :tested_revision,
    :tested_at,
    :last_error,
    :last_failed_at,
    enabled: false,
    credentials_configured: false
  ]

  @doc "Builds the public settings view from an internal persistence record."
  @spec from_schema(UserSmtpSettingsSchema.t()) :: t()
  def from_schema(%UserSmtpSettingsSchema{} = settings) do
    %__MODULE__{
      id: settings.id,
      host: settings.host,
      port: settings.port,
      security: settings.security,
      from_address: settings.from_address,
      from_name: settings.from_name,
      revision: settings.revision,
      tested_revision: settings.tested_revision,
      tested_at: settings.tested_at,
      last_error: settings.last_error,
      last_failed_at: settings.last_failed_at,
      enabled: settings.enabled,
      credentials_configured:
        is_binary(settings.username_encrypted) and is_binary(settings.password_encrypted)
    }
  end

  @doc "Identifies both the saved record and its revision for stale-form protection."
  @spec version(t()) :: version()
  def version(%__MODULE__{id: id, revision: revision}), do: {id, revision}
end
