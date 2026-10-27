defmodule Tymeslot.Telegram.TelegramIntegrationSchema do
  @moduledoc """
  Schema for Telegram integration records linking users to their Telegram bot configuration.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Notifications.EventTypes
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Token
  alias Tymeslot.Validation.Constraints

  @type status :: :pending_link | :active | :paused | :auto_disabled

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          bot_mode: String.t(),
          bot_token_encrypted: binary() | nil,
          bot_token: String.t() | nil,
          chat_id: String.t() | nil,
          link_token: String.t() | nil,
          link_token_hash: String.t() | nil,
          link_token_issued_at: DateTime.t() | nil,
          linked_at: DateTime.t() | nil,
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

  @valid_events EventTypes.all()

  @valid_bot_modes ["shared", "own"]
  @max_failure_count 10

  schema "telegram_integrations" do
    field(:name, :string)
    field(:bot_mode, :string, default: "own")
    field(:bot_token_encrypted, :binary)
    field(:chat_id, :string)
    # The one-time `/start` token of the shared bot's deep link. It is only
    # ever compared once issued, so the row keeps its hash; the virtual field
    # carries the token itself on the integration it was just issued to.
    field(:link_token, :string, virtual: true, redact: true)
    field(:link_token_hash, :string)
    field(:link_token_issued_at, :utc_datetime)
    field(:linked_at, :utc_datetime)
    field(:events, {:array, :string}, default: [])
    field(:is_active, :boolean, default: true)
    field(:last_triggered_at, :utc_datetime)
    field(:failure_count, :integer, default: 0)
    field(:disabled_at, :utc_datetime)
    field(:disabled_reason, :string)

    field(:bot_token, :string, virtual: true, redact: true)

    field(:status, Ecto.Enum,
      values: [:pending_link, :active, :paused, :auto_disabled],
      virtual: true
    )

    belongs_to(:user, Tymeslot.Auth.UserSchema)

    timestamps(type: :utc_datetime)
  end

  # Changesets are split by who is acting, so no caller can write a field it
  # has no business writing:
  #
  #   * `create_changeset/1` and `user_changeset/2` carry what the organiser
  #     types into the form. The chat and the token are theirs to set only
  #     on an own-bot integration; on the shared bot the chat is linked by
  #     `link_changeset/2` alone, after the bot has received the deep link.
  #   * `link_changeset/2` carries the link state, written only by the link
  #     flows and by delivery-time corrections.
  #   * `state_transition_changeset/2` carries the delivery bookkeeping.
  @own_bot_fields [:bot_token, :chat_id]

  @doc """
  Changeset for a new integration. `user_id` and `bot_mode` are set by the
  context, never taken from the form.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :bot_mode])
    |> validate_required([:user_id, :bot_mode])
    |> validate_inclusion(:bot_mode, @valid_bot_modes)
    |> user_changeset(attrs)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for the organiser's own edits: the name, the events and, on an
  own-bot integration only, the bot token and chat id. The bot mode is never
  changed here.
  """
  @spec user_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def user_changeset(integration, attrs) do
    changeset = change(integration)

    changeset
    |> cast(attrs, [:name, :events] ++ user_link_fields(get_field(changeset, :bot_mode)))
    |> validate_required([:name])
    |> validate_length(:name, Constraints.integration_name_length_opts())
    |> validate_subset(:events, @valid_events)
    |> stamp_linked_at()
    |> encrypt_token()
  end

  @doc """
  Changeset for the link state: the chat id and the one-time link token.
  Used by the link flows (`/start` payload, reconnect, disconnect, token
  refresh) and by the supergroup chat id migration, never by form input.
  """
  @spec link_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def link_changeset(integration, attrs) do
    integration
    |> cast(attrs, [:chat_id, :link_token])
    |> keep_explicit_link_token(attrs)
    |> stamp_link_token_issued_at()
    |> Token.put_hash(:link_token, :link_token_hash)
    |> stamp_linked_at()
  end

  @doc """
  Changeset for state transitions only (enable/disable, failure tracking,
  last-triggered stamp), so a row in any state can be updated without
  re-validating what the organiser entered.
  """
  @spec state_transition_changeset(t(), map()) :: Ecto.Changeset.t()
  def state_transition_changeset(integration, attrs) do
    cast(integration, attrs, [
      :is_active,
      :disabled_at,
      :disabled_reason,
      :last_triggered_at,
      :failure_count
    ])
  end

  defp user_link_fields("own"), do: @own_bot_fields
  defp user_link_fields(_bot_mode), do: []

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

  @encrypted_credential_fields [:bot_token_encrypted]

  @doc """
  Returns the list of encrypted credential field atoms on this schema. Used by
  `Tymeslot.Security.CredentialReencryption` so the authoritative list lives in
  one place.
  """
  @spec encrypted_credential_fields() :: [atom()]
  def encrypted_credential_fields, do: @encrypted_credential_fields

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

  # The token is virtual, so a loaded row carries nil and casting a nil over
  # it is no change at all. Clearing the token is still a change to its hash
  # and its issue time, so a token given explicitly always counts as one.
  defp keep_explicit_link_token(changeset, attrs) do
    given? = Map.has_key?(attrs, :link_token) or Map.has_key?(attrs, "link_token")

    if given? and not Map.has_key?(changeset.changes, :link_token),
      do: force_change(changeset, :link_token, get_field(changeset, :link_token)),
      else: changeset
  end

  # The issue time travels with the token, so no caller can hand out a token
  # the server cannot expire.
  defp stamp_link_token_issued_at(changeset) do
    case fetch_change(changeset, :link_token) do
      {:ok, nil} -> put_change(changeset, :link_token_issued_at, nil)
      {:ok, _token} -> put_change(changeset, :link_token_issued_at, DateTime.utc_now(:second))
      :error -> changeset
    end
  end

  # `linked_at` records that the integration has had a chat at some point, so
  # a disconnected integration (chat cleared) is never mistaken for an
  # abandoned setup stub. It is set once and never cleared.
  defp stamp_linked_at(%Ecto.Changeset{data: %{linked_at: %DateTime{}}} = changeset),
    do: changeset

  defp stamp_linked_at(%Ecto.Changeset{data: %{chat_id: nil}} = changeset) do
    case get_change(changeset, :chat_id) do
      nil -> changeset
      _chat_id -> put_change(changeset, :linked_at, DateTime.utc_now(:second))
    end
  end

  defp stamp_linked_at(changeset),
    do: put_change(changeset, :linked_at, DateTime.utc_now(:second))

  defp encrypt_token(changeset) do
    case get_change(changeset, :bot_token) do
      nil -> changeset
      "" -> changeset
      token -> put_change(changeset, :bot_token_encrypted, Encryption.encrypt(token))
    end
  end
end
