defmodule Tymeslot.EmailSending.Sender do
  @moduledoc """
  A notification execution's sending identity, without SMTP credentials.

  This runtime value freezes the selected From and configuration version
  across recipient copies. It is never written to job arguments. Credentials
  are fetched separately against the same owner, configuration ID and revision.
  """

  @enforce_keys [:kind, :from_name, :from_address]
  defstruct [:kind, :owner_id, :settings_id, :revision, :from_name, :from_address]

  @type t :: %__MODULE__{
          kind: :platform | :user_smtp,
          owner_id: pos_integer() | nil,
          settings_id: pos_integer() | nil,
          revision: pos_integer() | nil,
          from_name: String.t(),
          from_address: String.t()
        }

  @doc "Snapshots the platform From identity for an optional booking owner."
  @spec platform(pos_integer() | nil) :: t()
  def platform(owner_id \\ nil) do
    config = Application.get_env(:tymeslot, :email, [])

    %__MODULE__{
      kind: :platform,
      owner_id: owner_id,
      from_name: Keyword.get(config, :from_name),
      from_address: Keyword.get(config, :from_email)
    }
  end

  @doc "Snapshots the public identity and version of an enabled settings row."
  @spec from_settings(Tymeslot.EmailSending.UserSmtpSettingsSchema.t()) :: t()
  def from_settings(settings) do
    %__MODULE__{
      kind: :user_smtp,
      owner_id: settings.user_id,
      settings_id: settings.id,
      revision: settings.revision,
      from_name: settings.from_name,
      from_address: settings.from_address
    }
  end

  @doc "Copies an execution identity into derived details without changing legacy payloads."
  @spec copy_from(map(), map()) :: map()
  def copy_from(details, %{email_sender: %__MODULE__{} = sender}) when is_map(details),
    do: Map.put(details, :email_sender, sender)

  def copy_from(details, resource) when is_map(details) and is_map(resource), do: details
end
