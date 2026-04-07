defmodule Tymeslot.Webhooks.WebhookDeliverySchema do
  @moduledoc """
  Ecto schema for webhook delivery logs.

  Tracks each webhook delivery attempt including the payload sent,
  response received, and any errors encountered. Used for debugging
  and monitoring webhook reliability.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Webhooks.WebhookSchema

  @type t :: %__MODULE__{
          id: binary() | nil,
          webhook_id: integer() | nil,
          event_type: String.t() | nil,
          meeting_id: binary() | nil,
          payload: map() | nil,
          response_status: integer() | nil,
          response_body: String.t() | nil,
          error_message: String.t() | nil,
          delivered_at: DateTime.t() | nil,
          attempt_count: integer(),
          webhook: WebhookSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :id

  schema "webhook_deliveries" do
    field(:event_type, :string)
    field(:meeting_id, :binary_id)
    field(:payload, :map)
    field(:response_status, :integer)
    field(:response_body, :string)
    field(:error_message, :string)
    field(:delivered_at, :utc_datetime)
    field(:attempt_count, :integer, default: 1)

    belongs_to(:webhook, WebhookSchema)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required_fields [:webhook_id, :event_type, :payload]
  @optional_fields [
    :meeting_id,
    :response_status,
    :response_body,
    :error_message,
    :delivered_at,
    :attempt_count
  ]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:webhook_id)
  end

  @doc """
  Checks if the delivery was successful
  """
  @spec successful?(t()) :: boolean()
  def successful?(%__MODULE__{response_status: status})
      when is_integer(status) and status >= 200 and status < 300,
      do: true

  def successful?(_other), do: false

  @doc """
  Checks if the delivery is retryable
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{response_status: 429}), do: true

  def retryable?(%__MODULE__{response_status: status})
      when is_integer(status) and status >= 500,
      do: true

  def retryable?(%__MODULE__{response_status: nil}), do: true
  def retryable?(_other), do: false

  @doc """
  Gets a human-readable status message
  """
  @spec status_message(t()) :: String.t()
  def status_message(%__MODULE__{} = delivery) do
    cond do
      successful?(delivery) ->
        "Success"

      delivery.error_message ->
        "Error: #{delivery.error_message}"

      delivery.response_status == 429 ->
        "Rate limited"

      is_integer(delivery.response_status) and delivery.response_status >= 500 ->
        "Server error"

      is_integer(delivery.response_status) and delivery.response_status >= 400 ->
        "Client error"

      true ->
        "Pending"
    end
  end
end
