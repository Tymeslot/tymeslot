defmodule Tymeslot.DatabaseSchemas.TelegramIntegrationSchema do
  @moduledoc """
  Schema for Telegram integration records linking users to their Telegram bot configuration.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Security.Encryption

  @type status :: :pending_link | :active | :paused | :auto_disabled

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          bot_mode: String.t(),
          bot_token_encrypted: binary() | nil,
          bot_token: String.t() | nil,
          chat_id: String.t() | nil,
          events: [String.t()],
          is_active: boolean(),
          last_triggered_at: DateTime.t() | nil,
          failure_count: integer(),
          disabled_at: DateTime.t() | nil,
          disabled_reason: String.t() | nil,
          status: status() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @valid_events [
    "meeting.created",
    "meeting.cancelled",
    "meeting.rescheduled"
  ]

  @valid_bot_modes ["shared", "own"]
  @max_failure_count 10

  schema "telegram_integrations" do
    field(:name, :string)
    field(:bot_mode, :string, default: "own")
    field(:bot_token_encrypted, :binary)
    field(:chat_id, :string)
    field(:events, {:array, :string}, default: [])
    field(:is_active, :boolean, default: true)
    field(:last_triggered_at, :utc_datetime)
    field(:failure_count, :integer, default: 0)
    field(:disabled_at, :utc_datetime)
    field(:disabled_reason, :string)

    field(:bot_token, :string, virtual: true)
    field(:status, Ecto.Enum, values: [:pending_link, :active, :paused, :auto_disabled], virtual: true)

    belongs_to(:user, Tymeslot.DatabaseSchemas.UserSchema)

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :user_id, :bot_mode]
  @optional_fields [
    :bot_token,
    :chat_id,
    :events,
    :is_active,
    :last_triggered_at,
    :failure_count,
    :disabled_at,
    :disabled_reason
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(integration, attrs) do
    integration
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:bot_mode, @valid_bot_modes)
    |> validate_events()
    |> encrypt_token()
    |> foreign_key_constraint(:user_id)
  end

  @spec derive_status(t()) :: t()
  def derive_status(%__MODULE__{} = integration) do
    status =
      cond do
        is_nil(integration.chat_id) -> :pending_link
        not integration.is_active and not is_nil(integration.disabled_at) -> :auto_disabled
        not integration.is_active -> :paused
        true -> :active
      end

    %{integration | status: status}
  end

  @spec decrypt_token(t()) :: t()
  def decrypt_token(%__MODULE__{bot_token_encrypted: nil} = integration), do: integration

  def decrypt_token(%__MODULE__{} = integration) do
    %{integration | bot_token: Encryption.decrypt(integration.bot_token_encrypted)}
  end

  @spec valid_events() :: [String.t()]
  def valid_events, do: @valid_events

  @spec subscribed_to?(t(), String.t()) :: boolean()
  def subscribed_to?(%__MODULE__{events: events}, event_type), do: event_type in events

  @spec should_be_active?(t()) :: boolean()
  def should_be_active?(%__MODULE__{is_active: false}), do: false
  def should_be_active?(%__MODULE__{chat_id: nil}), do: false
  def should_be_active?(%__MODULE__{disabled_at: %DateTime{}}), do: false
  def should_be_active?(%__MODULE__{failure_count: count}) when count >= @max_failure_count,
    do: false

  def should_be_active?(_other), do: true

  @spec max_failure_count() :: integer()
  def max_failure_count, do: @max_failure_count

  defp validate_events(changeset) do
    case get_change(changeset, :events) do
      nil ->
        changeset

      events ->
        invalid = Enum.reject(events, &(&1 in @valid_events))

        if Enum.empty?(invalid) do
          changeset
        else
          add_error(changeset, :events, "contains invalid events: #{Enum.join(invalid, ", ")}")
        end
    end
  end

  defp encrypt_token(changeset) do
    case get_change(changeset, :bot_token) do
      nil -> changeset
      "" -> changeset
      token -> put_change(changeset, :bot_token_encrypted, Encryption.encrypt(token))
    end
  end
end
