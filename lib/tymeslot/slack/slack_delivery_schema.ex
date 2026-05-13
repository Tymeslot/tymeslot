defmodule Tymeslot.Slack.SlackDeliverySchema do
  @moduledoc """
  Schema for tracking individual Slack message delivery attempts and their
  outcomes. Each row records the Block Kit payload that was sent, the response
  Slack returned, and any error encountered.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Slack.SlackIntegrationSchema

  @type t :: %__MODULE__{
          id: binary() | nil,
          integration_id: integer() | nil,
          event_type: String.t() | nil,
          meeting_id: String.t() | nil,
          message_blocks: map() | nil,
          response_status: integer() | nil,
          response_body: String.t() | nil,
          error_message: String.t() | nil,
          delivered_at: DateTime.t() | nil,
          attempt_count: integer(),
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :id

  schema "slack_deliveries" do
    field(:event_type, :string)
    field(:meeting_id, :string)
    field(:message_blocks, :map)
    field(:response_status, :integer)
    field(:response_body, :string)
    field(:error_message, :string)
    field(:delivered_at, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 1)

    belongs_to(:integration, SlackIntegrationSchema, define_field: false)
    field(:integration_id, :id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:integration_id, :event_type]
  @optional_fields [
    :meeting_id,
    :message_blocks,
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
  def successful?(%__MODULE__{response_status: status, error_message: err})
      when is_integer(status) and status in 200..299 and is_nil(err),
      do: true

  def successful?(%__MODULE__{}), do: false
end
