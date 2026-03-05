defmodule Tymeslot.DatabaseSchemas.TelegramDeliverySchema do
  @moduledoc """
  Schema for tracking individual Telegram message delivery attempts and their outcomes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.DatabaseSchemas.TelegramIntegrationSchema

  @type t :: %__MODULE__{
          id: binary() | nil,
          integration_id: integer() | nil,
          event_type: String.t() | nil,
          meeting_id: binary() | nil,
          message_text: String.t() | nil,
          response_status: integer() | nil,
          response_body: String.t() | nil,
          error_message: String.t() | nil,
          delivered_at: DateTime.t() | nil,
          attempt_count: integer(),
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :id

  schema "telegram_deliveries" do
    field(:event_type, :string)
    field(:meeting_id, :binary_id)
    field(:message_text, :string)
    field(:response_status, :integer)
    field(:response_body, :string)
    field(:error_message, :string)
    field(:delivered_at, :utc_datetime)
    field(:attempt_count, :integer, default: 1)

    belongs_to(:integration, TelegramIntegrationSchema)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required_fields [:integration_id, :event_type]
  @optional_fields [
    :meeting_id,
    :message_text,
    :response_status,
    :response_body,
    :error_message,
    :delivered_at,
    :attempt_count
  ]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:integration_id)
  end

  @spec successful?(t()) :: boolean()
  def successful?(%__MODULE__{response_status: status})
      when is_integer(status) and status >= 200 and status < 300,
      do: true

  def successful?(_delivery), do: false
end
