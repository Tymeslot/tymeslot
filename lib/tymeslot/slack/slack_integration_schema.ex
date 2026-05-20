defmodule Tymeslot.Slack.SlackIntegrationSchema do
  @moduledoc """
  Schema for Slack integration records linking users to either a Slack
  workspace via OAuth (`app_mode: "oauth"`) or a pasted Incoming Webhook URL
  (`app_mode: "webhook_url"`).

  Sensitive credentials (`bot_token`, `webhook_url`) are AES-encrypted at rest
  using `Tymeslot.Security.Encryption`. Plaintext access is exposed via the
  `bot_token/1` and `webhook_url/1` helpers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Security.Encryption

  @type status :: :pending_oauth | :active | :paused | :auto_disabled

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          app_mode: String.t() | nil,
          bot_token: String.t() | nil,
          bot_token_encrypted: binary() | nil,
          team_id: String.t() | nil,
          team_name: String.t() | nil,
          channel_id: String.t() | nil,
          channel_name: String.t() | nil,
          authed_user_id: String.t() | nil,
          scope: String.t() | nil,
          link_token: String.t() | nil,
          webhook_url: String.t() | nil,
          webhook_url_encrypted: binary() | nil,
          webhook_channel_hint: String.t() | nil,
          events: [String.t()],
          is_active: boolean(),
          last_triggered_at: DateTime.t() | nil,
          failure_count: integer(),
          disabled_at: DateTime.t() | nil,
          disabled_reason: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @valid_events ~w(meeting.created meeting.cancelled meeting.rescheduled)
  @valid_modes ~w(oauth webhook_url)
  @webhook_url_regex ~r{\Ahttps://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+\z}

  schema "slack_integrations" do
    field(:name, :string)
    field(:app_mode, :string)

    field(:bot_token, :string, virtual: true)
    field(:bot_token_encrypted, :binary)

    field(:team_id, :string)
    field(:team_name, :string)
    field(:channel_id, :string)
    field(:channel_name, :string)
    field(:authed_user_id, :string)
    field(:scope, :string)
    field(:link_token, :string)

    field(:webhook_url, :string, virtual: true)
    field(:webhook_url_encrypted, :binary)
    field(:webhook_channel_hint, :string)

    field(:events, {:array, :string}, default: [])
    field(:is_active, :boolean, default: true)
    field(:last_triggered_at, :utc_datetime_usec)
    field(:failure_count, :integer, default: 0)
    field(:disabled_at, :utc_datetime_usec)
    field(:disabled_reason, :string)

    belongs_to(:user, UserSchema, define_field: false)
    field(:user_id, :id)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :user_id,
    :name,
    :app_mode,
    :bot_token,
    :team_id,
    :team_name,
    :channel_id,
    :channel_name,
    :authed_user_id,
    :scope,
    :link_token,
    :webhook_url,
    :webhook_channel_hint,
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
    |> cast(attrs, @cast_fields)
    |> validate_required([:user_id, :name, :app_mode, :events])
    |> validate_inclusion(:app_mode, @valid_modes)
    |> validate_subset(:events, @valid_events)
    |> validate_length(:name, min: 1, max: 80)
    |> validate_by_mode()
    |> encrypt_bot_token()
    |> encrypt_webhook_url()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :team_id],
      name: :slack_integrations_user_team_unique_index,
      message: "workspace already connected"
    )
  end

  @doc """
  Changeset for the partial OAuth-completed state, before the user has picked a channel.

  Use this in `Slack.complete_oauth/2` to persist the bot_token + workspace info
  immediately after a successful OAuth exchange. The integration stays in
  `:pending_oauth` status until `set_channel_changeset/2` populates `channel_id`.
  """
  @spec oauth_init_changeset(t(), map()) :: Ecto.Changeset.t()
  def oauth_init_changeset(integration, attrs) do
    integration
    |> cast(attrs, [
      :user_id,
      :name,
      :app_mode,
      :bot_token,
      :team_id,
      :team_name,
      :authed_user_id,
      :scope,
      :link_token,
      :events
    ])
    |> validate_required([:user_id, :name, :app_mode, :bot_token, :team_id, :events])
    |> validate_inclusion(:app_mode, @valid_modes)
    |> validate_subset(:events, @valid_events)
    |> validate_length(:name, min: 1, max: 80)
    |> encrypt_bot_token()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :team_id],
      name: :slack_integrations_user_team_unique_index,
      message: "workspace already connected"
    )
  end

  @doc """
  Changeset for transitioning a `:pending_oauth` integration to `:active` by
  setting the channel. Only the channel fields are cast; everything else on the
  record is preserved. Always sets `is_active: true` and clears any
  `disabled_at`/`disabled_reason` so that a user who re-runs OAuth after
  having previously paused or auto-disabled an integration gets an active one.
  """
  @spec set_channel_changeset(t(), map()) :: Ecto.Changeset.t()
  def set_channel_changeset(integration, attrs) do
    integration
    |> cast(attrs, [:channel_id, :channel_name])
    |> validate_required([:channel_id])
    |> put_change(:is_active, true)
    |> put_change(:disabled_at, nil)
    |> put_change(:disabled_reason, nil)
  end

  @doc """
  Minimal changeset for state-transition-only updates (enable/disable, failure
  tracking, last-triggered stamp). Bypasses `validate_by_mode` and encryption
  helpers so that records in any state — including `channel_id: nil` stubs —
  can be updated without re-supplying credential fields.
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

  @doc """
  Changeset for demoting an active OAuth integration back to `:pending_oauth`
  by clearing its channel selection. The stored bot token and workspace info
  are preserved so the user can pick a new channel without redoing OAuth.
  Bypasses `validate_by_mode` so that the resulting `channel_id: nil` state
  is acceptable.
  """
  @spec disconnect_changeset(t()) :: Ecto.Changeset.t()
  def disconnect_changeset(integration) do
    integration
    |> cast(%{}, [])
    |> put_change(:channel_id, nil)
    |> put_change(:channel_name, nil)
  end

  defp validate_by_mode(changeset) do
    case get_field(changeset, :app_mode) do
      "oauth" ->
        changeset
        |> validate_token_present()
        |> validate_required([:channel_id])

      "webhook_url" ->
        changeset
        |> validate_webhook_url_present()
        |> validate_format(:webhook_url, @webhook_url_regex,
          message: "must be a Slack webhook URL (https://hooks.slack.com/services/...)"
        )

      _mode ->
        changeset
    end
  end

  # bot_token is virtual; once the record is persisted, the plaintext is gone
  # but bot_token_encrypted remains. Treat either as sufficient evidence the
  # integration has a token, so updates of stored records succeed without
  # re-supplying the token.
  defp validate_token_present(changeset) do
    cond do
      get_field(changeset, :bot_token) not in [nil, ""] -> changeset
      get_field(changeset, :bot_token_encrypted) not in [nil, ""] -> changeset
      true -> add_error(changeset, :bot_token, "can't be blank")
    end
  end

  defp validate_webhook_url_present(changeset) do
    cond do
      get_field(changeset, :webhook_url) not in [nil, ""] -> changeset
      get_field(changeset, :webhook_url_encrypted) not in [nil, ""] -> changeset
      true -> add_error(changeset, :webhook_url, "can't be blank")
    end
  end

  defp encrypt_bot_token(changeset) do
    case get_change(changeset, :bot_token) do
      nil -> changeset
      "" -> changeset
      plaintext -> put_change(changeset, :bot_token_encrypted, Encryption.encrypt(plaintext))
    end
  end

  defp encrypt_webhook_url(changeset) do
    case get_change(changeset, :webhook_url) do
      nil -> changeset
      "" -> changeset
      plaintext -> put_change(changeset, :webhook_url_encrypted, Encryption.encrypt(plaintext))
    end
  end

  @doc "Decrypts the stored bot token. Returns nil for non-OAuth integrations."
  @spec bot_token(t()) :: String.t() | nil
  def bot_token(%__MODULE__{bot_token_encrypted: nil}), do: nil
  def bot_token(%__MODULE__{bot_token_encrypted: ct}), do: Encryption.decrypt(ct)

  @doc "Decrypts the stored webhook URL. Returns nil for non-webhook integrations."
  @spec webhook_url(t()) :: String.t() | nil
  def webhook_url(%__MODULE__{webhook_url_encrypted: nil}), do: nil
  def webhook_url(%__MODULE__{webhook_url_encrypted: ct}), do: Encryption.decrypt(ct)

  @doc """
  Derives a high-level status from the integration's stored fields.

  Returns:
    * `:pending_oauth` — OAuth flow started but channel not yet picked
    * `:paused` — User toggled off
    * `:auto_disabled` — Auto-disabled due to repeated failures or token revocation
    * `:active` — Ready to send
  """
  @spec status(t()) :: status()
  def status(%__MODULE__{disabled_at: %DateTime{}}), do: :auto_disabled
  def status(%__MODULE__{is_active: false}), do: :paused
  def status(%__MODULE__{app_mode: "oauth", channel_id: nil}), do: :pending_oauth
  def status(%__MODULE__{app_mode: "oauth", bot_token_encrypted: nil}), do: :pending_oauth
  def status(%__MODULE__{}), do: :active

  @spec subscribed_to?(t(), String.t()) :: boolean()
  def subscribed_to?(%__MODULE__{events: events}, event), do: event in events

  @spec valid_events() :: [String.t()]
  def valid_events, do: @valid_events
end
