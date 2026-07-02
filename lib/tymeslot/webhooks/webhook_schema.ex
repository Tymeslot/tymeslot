defmodule Tymeslot.Webhooks.WebhookSchema do
  @moduledoc """
  Ecto schema for webhooks.

  Allows users to configure HTTP endpoints that receive notifications
  when specific booking events occur (created, cancelled, rescheduled, etc.).
  Enables integration with automation tools like n8n, Zapier, Make.com.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.URL, as: URLValidator
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Webhooks.SsrfValidator

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          url: String.t() | nil,
          webhook_token_encrypted: binary() | nil,
          events: [String.t()],
          is_active: boolean(),
          last_triggered_at: DateTime.t() | nil,
          last_status: String.t() | nil,
          failure_count: integer(),
          disabled_at: DateTime.t() | nil,
          disabled_reason: String.t() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          webhook_token: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "webhooks" do
    field(:name, :string)
    field(:url, :string)
    field(:webhook_token_encrypted, :binary)
    field(:events, {:array, :string}, default: [])
    field(:is_active, :boolean, default: true)
    field(:last_triggered_at, :utc_datetime)
    field(:last_status, :string)
    field(:failure_count, :integer, default: 0)
    field(:disabled_at, :utc_datetime)
    field(:disabled_reason, :string)

    # Virtual field for decrypted token
    field(:webhook_token, :string, virtual: true)

    belongs_to(:user, Tymeslot.Auth.UserSchema)

    timestamps(type: :utc_datetime)
  end

  @valid_events [
    "meeting.created",
    "meeting.cancelled",
    "meeting.rescheduled"
  ]

  @required_fields [:name, :url, :user_id]
  @optional_fields [
    :webhook_token,
    :events,
    :is_active,
    :last_triggered_at,
    :last_status,
    :failure_count,
    :disabled_at,
    :disabled_reason
  ]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(webhook, attrs) do
    # Ensure attrs is a map
    attrs = attrs || %{}

    # If webhook_token is explicitly set to nil in attrs, ensure it stays nil after cast
    # so generate_token can detect it.
    changeset =
      webhook
      |> cast(attrs, @required_fields ++ @optional_fields)
      |> validate_required(@required_fields)
      |> validate_length(:name, Constraints.webhook_name_length_opts())
      |> validate_length(:url, min: 1, max: Constraints.url_max_length())
      |> URLValidator.validate_url(:url,
        block_private_ips: not SsrfValidator.allow_private?(),
        enforce_https: not SsrfValidator.allow_private?()
      )
      |> validate_events()
      |> foreign_key_constraint(:user_id)

    changeset =
      if Map.has_key?(attrs, :webhook_token) or Map.has_key?(attrs, "webhook_token") do
        val = attrs[:webhook_token] || attrs["webhook_token"]

        if is_nil(val) or val == "" do
          put_change(changeset, :webhook_token, generate_secure_token())
        else
          changeset
        end
      else
        changeset
      end

    changeset
    |> generate_token()
    |> encrypt_token()
  end

  @doc """
  Decrypts the webhook token field.
  """
  @spec decrypt_token(t()) :: t()
  def decrypt_token(%__MODULE__{} = webhook) do
    %{webhook | webhook_token: Encryption.decrypt(webhook.webhook_token_encrypted)}
  end

  @doc """
  Returns all valid event types
  """
  @spec valid_events() :: [String.t()]
  def valid_events, do: @valid_events

  @doc """
  Checks if webhook should be active (not disabled by failures)
  """
  @spec should_be_active?(t()) :: boolean()
  def should_be_active?(%__MODULE__{is_active: false}), do: false
  def should_be_active?(%__MODULE__{disabled_at: %DateTime{}}), do: false
  def should_be_active?(%__MODULE__{failure_count: count}) when count >= 10, do: false
  def should_be_active?(_webhook), do: true

  @doc """
  Checks if webhook is subscribed to a specific event
  """
  @spec subscribed_to?(t(), String.t()) :: boolean()
  def subscribed_to?(%__MODULE__{events: events}, event_type) do
    event_type in events
  end

  # Private functions

  defp validate_events(changeset) do
    case get_change(changeset, :events) do
      nil ->
        changeset

      events ->
        case validate_events_list(events) do
          :ok -> changeset
          {:error, msg} -> add_error(changeset, :events, msg)
        end
    end
  end

  @doc """
  Validates a list of event types.
  Returns :ok or {:error, message}
  """
  @spec validate_events_list([String.t()]) :: :ok | {:error, String.t()}
  def validate_events_list([]) do
    {:error, "must select at least one event"}
  end

  def validate_events_list(events) when is_list(events) do
    invalid_events = Enum.reject(events, &(&1 in @valid_events))

    if Enum.empty?(invalid_events) do
      :ok
    else
      {:error, "contains invalid events: #{Enum.join(invalid_events, ", ")}"}
    end
  end

  @doc """
  Generates a new secure webhook token.
  """
  @spec generate_secure_token() :: String.t()
  def generate_secure_token do
    "ts_" <> Base.encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp generate_token(changeset) do
    # For new records, generate a token if not already present
    if get_field(changeset, :webhook_token_encrypted) || get_change(changeset, :webhook_token) do
      changeset
    else
      put_change(changeset, :webhook_token, generate_secure_token())
    end
  end

  defp encrypt_token(changeset) do
    case get_change(changeset, :webhook_token) do
      nil ->
        changeset

      "" ->
        changeset

      token ->
        put_change(changeset, :webhook_token_encrypted, Encryption.encrypt(token))
    end
  end
end
