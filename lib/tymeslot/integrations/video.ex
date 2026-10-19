defmodule Tymeslot.Integrations.Video do
  @moduledoc """
  UI-agnostic facade for video integration business logic.

  Exposes a cohesive API used by web components without any LiveView/socket coupling.
  """

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video.AccessToken
  alias Tymeslot.Integrations.Video.AccountKey
  alias Tymeslot.Integrations.Video.AttrsCasting
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Integrations.Video.Disconnect
  alias Tymeslot.Integrations.Video.MeetingLinkTemplate
  alias Tymeslot.Integrations.Video.OAuth
  alias Tymeslot.Integrations.Video.OAuthCallback
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.Rooms
  alias Tymeslot.Integrations.Video.Update
  alias Tymeslot.Integrations.Video.Urls
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.EncryptedString

  @behaviour Tymeslot.Security.EncryptedStorage

  @type provider ::
          :google_meet
          | :teams
          | :zoom
          | :mirotalk
          | :custom
          | :kmeet
          | :jitsi
          | :nextcloud_talk
          | :none
          | String.t()

  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do:
      {VideoIntegrationSchema.__schema__(:source),
       VideoIntegrationSchema.encrypted_credential_fields() ++
         EncryptedString.columns(VideoIntegrationSchema)}

  # ---------------
  # Read
  # ---------------
  @spec list_integrations(pos_integer()) :: list()
  def list_integrations(user_id) when is_integer(user_id) do
    VideoIntegrationQueries.list_all_for_user(user_id)
  end

  @doc """
  The user's active video integrations, ordered by name, credentials left
  encrypted: for listings that need the id, name and provider.
  """
  @spec list_active_integrations(pos_integer()) :: [VideoIntegrationSchema.t()]
  def list_active_integrations(user_id) when is_integer(user_id),
    do: VideoIntegrationQueries.list_active_for_user(user_id)

  @doc "Whether the user has an active video integration."
  @spec has_active_integration?(pos_integer()) :: boolean()
  def has_active_integration?(user_id) when is_integer(user_id),
    do: VideoIntegrationQueries.active_exists_for_user?(user_id)

  @doc "See `Tymeslot.Integrations.Video.MeetingLinkTemplate.invalid?/1`."
  @spec meeting_link_template_invalid?(map()) :: boolean()
  defdelegate meeting_link_template_invalid?(integration), to: MeetingLinkTemplate, as: :invalid?

  @doc """
  Gets a single video integration by ID for a specific user.

  Returns `{:error, :requires_reencryption, integration}` for an owned
  integration whose credentials no longer decrypt; the row is real and the
  caller decides what to do with it. Callers that only want the two-outcome
  shape should use `fetch_integration_for_user/2` instead.
  """
  @spec get_integration(pos_integer(), pos_integer()) ::
          {:ok, VideoIntegrationSchema.t()}
          | {:error, :not_found}
          | {:error, :requires_reencryption, VideoIntegrationSchema.t()}
  def get_integration(user_id, id) when is_integer(user_id) and is_integer(id) do
    VideoIntegrationQueries.get_live_for_user(id, user_id)
  end

  @doc """
  Entry point for the "credentials no longer decrypt" path, used by any
  worker or caller that receives `{:error, :requires_reencryption, integration}`
  from `VideoIntegrationQueries.get/1` or `VideoIntegrationQueries.get_for_user/2`.

  Pass `cause: cause` (see `t:Tymeslot.Integrations.Shared.ReauthHandling.cause/0`)
  when the integration needs reconnecting for a different reason, so the message
  recorded on `sync_error` describes what actually failed.

  Returns an Oban return value: `{:discard, _}` once flagged (retrying won't
  recover the credentials) or when the integration's row is gone, and
  `{:error, _}` when the flag could not be recorded with its email, so Oban
  retries the job and takes another shot. Credentials under an encryption key
  missing from the keyring are not flagged (see `ReauthHandling.flag/3`): the
  job is discarded with `ReauthHandling.key_missing_discard_reason/0`.
  """
  @spec handle_reauth_required(VideoIntegrationSchema.t(), keyword()) ::
          {:discard, String.t()} | {:error, String.t()}
  def handle_reauth_required(%VideoIntegrationSchema{} = integration, opts \\ []) do
    case flag_for_reauth(integration, opts) do
      :ok -> {:discard, ReauthHandling.discard_reason()}
      {:error, :not_found} -> {:discard, "Integration no longer exists"}
      {:error, :notification_failed} -> {:error, "Failed to flag integration for reauth"}
      {:error, :encryption_key_missing} -> {:discard, ReauthHandling.key_missing_discard_reason()}
    end
  end

  @doc """
  Fetches a video integration by ID for a specific user, collapsing the
  `{:error, :requires_reencryption, integration}` arm into `{:error, :not_found}`
  after silently flagging the integration for reauthentication.

  Use this in non-Oban callers that only care about the two-outcome
  `{:ok, _} | {:error, :not_found}` shape.
  """
  @spec fetch_integration_for_user(integer(), integer()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def fetch_integration_for_user(id, user_id),
    do: fetch_flagging_unreadable(VideoIntegrationQueries.get_for_user(id, user_id))

  @doc """
  As `fetch_integration_for_user/2`, but a disconnected (soft-deleted)
  integration is not found. For what the owner does, as against background
  cleanup.
  """
  @spec fetch_live_integration_for_user(integer(), integer()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def fetch_live_integration_for_user(id, user_id),
    do: fetch_flagging_unreadable(VideoIntegrationQueries.get_live_for_user(id, user_id))

  defp fetch_flagging_unreadable(lookup) do
    case lookup do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :requires_reencryption, stale} ->
        flag_for_reauth(stale)
        {:error, :not_found}
    end
  end

  defp flag_for_reauth(integration, opts \\ []) do
    ReauthHandling.flag(
      :video,
      integration,
      Keyword.get(opts, :cause, :credentials_undecryptable)
    )
  end

  # ---------------
  # Create
  # ---------------
  @spec create_integration(
          pos_integer(),
          provider(),
          %{(String.t() | atom()) => term()}
        ) ::
          {:ok, any()} | {:error, any()}
  def create_integration(user_id, provider, attrs) when is_integer(user_id) and is_map(attrs) do
    case ProviderConfig.parse(provider) do
      {:ok, provider} ->
        attrs
        |> AttrsCasting.atomize_known_attrs()
        |> Map.merge(%{user_id: user_id, provider: to_string(provider)})
        |> then(&create_pipeline(provider, account_attrs(provider, &1)))
        |> AccountKey.refuse_taken_key()

      {:error, :unknown} ->
        {:error, :unknown_provider}
    end
  end

  # One order for every provider. Everything before the probe is decided
  # in-process; the probe is an outbound request to an address the organiser
  # typed, which the connection-test bucket meters, so a repeat or a
  # submission the changeset would refuse never spends one. OAuth providers
  # are connected through their callback (`complete_oauth/4`) rather than
  # here, so they skip the checks that need a user-supplied config.
  defp create_pipeline(provider, attrs) do
    with :ok <- check_no_duplicate(provider, attrs),
         :ok <- validate_new_config(provider, attrs),
         :ok <- probe_on_create(provider, attrs) do
      create(attrs)
    end
  end

  # The account key a provider's integrations are deduplicated on: the
  # address for the URL-keyed providers, server and login for Nextcloud Talk.
  defp account_attrs(provider, attrs) do
    case {provider, AccountKey.url_field(provider)} do
      {:nextcloud_talk, _field} ->
        NextcloudTalkProvider.account_attrs(attrs)

      {_provider, nil} ->
        attrs

      {_provider, field} ->
        Map.put(attrs, :provider_account_id, AccountKey.key_for(provider, attrs[field]))
    end
  end

  # A provider keyed on an account cannot be connected to the same one twice;
  # one keyed on nothing (kMeet's single host) once per user.
  defp check_no_duplicate(provider, %{user_id: user_id} = attrs) do
    cond do
      attrs[:provider_account_id] not in [nil, ""] ->
        AccountKey.check_free(user_id, attrs.provider, attrs.provider_account_id, nil)

      ProviderConfig.oauth_provider?(provider) or provider == :none ->
        :ok

      true ->
        case VideoIntegrationQueries.get_by_provider_for_user(user_id, attrs.provider) do
          {:ok, _connected} -> {:error, :provider_already_connected}
          {:error, :not_found} -> :ok
        end
    end
  end

  defp validate_new_config(provider, attrs) do
    if ProviderConfig.oauth_provider?(provider) or provider == :none do
      :ok
    else
      with {:ok, module} <- ProviderConfig.get_provider(provider),
           :ok <- module.validate_config(attrs),
           :ok <- validate_for_save(module, attrs) do
        VideoIntegrationSchema.validate_new(attrs)
      end
    end
  end

  defp validate_for_save(module, attrs) do
    if function_exported?(module, :validate_config_for_save, 1),
      do: module.validate_config_for_save(attrs),
      else: :ok
  end

  defp probe_on_create(provider, attrs) do
    if ProviderConfig.probes_on_create?(provider) do
      with {:ok, module} <- ProviderConfig.get_provider(provider),
           config = Map.take(attrs, Map.keys(module.config_schema())),
           {:ok, _message} <- Connection.probe(provider, config, {:user, attrs.user_id}),
           do: :ok
    else
      :ok
    end
  end

  # kMeet's single-host rule also lives in a unique index, which a concurrent
  # connect can still meet; its refusal is answered as the duplicate check
  # answers.
  defp create(attrs) do
    case VideoIntegrationQueries.create(attrs) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if provider_already_connected?(changeset),
          do: {:error, :provider_already_connected},
          else: error

      result ->
        result
    end
  end

  defp provider_already_connected?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(Keyword.get_values(errors, :provider), fn {_message, opts} ->
      opts[:constraint] == :unique
    end)
  end

  # ---------------
  # Update
  # ---------------
  @doc """
  Updates a video integration owned by `user_id`. See
  `Tymeslot.Integrations.Video.Update` for how credentials are kept, replaced
  and removed.
  """
  @spec update_integration(pos_integer(), pos_integer(), %{(String.t() | atom()) => term()}) ::
          {:ok, any()} | {:error, any()}
  defdelegate update_integration(user_id, id, attrs), to: Update, as: :run

  # ---------------
  # Delete
  # ---------------
  @doc """
  Disconnects a video integration.

  With `delete_rooms: true` the integration is soft-deleted and a background job
  deletes the provider-side rooms covered by `disconnect_room_scope/1` before
  purging the row. Without it the row goes immediately and existing rooms are left
  running, so join URLs already sitting in attendees' calendar invites keep
  working.
  """
  @spec delete_integration(pos_integer(), pos_integer(), keyword()) ::
          {:ok, :deleted | :cleanup_scheduled} | {:error, any()}
  defdelegate delete_integration(user_id, id, opts \\ []), to: Disconnect, as: :run

  @doc """
  Which of an integration's rooms disconnecting with `delete_rooms: true`
  deletes, for the given provider: `:upcoming` bookings' rooms only, or `:all`
  the rooms it still holds for a provider whose rooms never expire.
  """
  @spec disconnect_room_scope(String.t()) :: :upcoming | :all
  defdelegate disconnect_room_scope(provider), to: Disconnect, as: :room_scope

  @doc """
  The scope and number of rooms disconnecting the user's integration with
  `delete_rooms: true` would delete. The count is zero when there is nothing
  such a disconnect could delete.
  """
  @spec rooms_deleted_on_disconnect(pos_integer(), pos_integer()) :: %{
          scope: :upcoming | :all,
          count: non_neg_integer()
        }
  defdelegate rooms_deleted_on_disconnect(user_id, id), to: Disconnect, as: :rooms_to_delete

  @doc """
  Removes every video integration matching `(provider, provider_account_id)`,
  regardless of the owning user. Used by provider-initiated revocation flows —
  for example, when a Zoom user uninstalls the app, Zoom's deauthorization
  webhook tells us the Zoom account ID but not the Tymeslot user, so we strip
  every Tymeslot integration referencing that account.
  """
  @spec disconnect_by_provider_account(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def disconnect_by_provider_account(provider, provider_account_id)
      when is_binary(provider) and is_binary(provider_account_id) do
    VideoIntegrationQueries.delete_by_provider_account(provider, provider_account_id)
  end

  # ---------------
  # Toggle active
  # ---------------
  @doc """
  Pauses an integration: sets it inactive, never the other way round. For
  the system pausing an unhealthy integration; the owner's own switch is
  `toggle_integration/2`.
  """
  @spec pause_integration(VideoIntegrationSchema.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def pause_integration(%VideoIntegrationSchema{} = integration) do
    VideoIntegrationQueries.deactivate(integration)
  end

  @spec toggle_integration(pos_integer(), pos_integer()) :: {:ok, any()} | {:error, any()}
  def toggle_integration(user_id, id) when is_integer(user_id) do
    case VideoIntegrationQueries.get_live_for_user(id, user_id) do
      {:ok, integration} ->
        case VideoIntegrationQueries.toggle_active(integration) do
          {:ok, %{is_active: true} = updated} = ok ->
            HealthCheck.mark_user_recovered(:video, updated.id)
            ok

          result ->
            result
        end

      {:error, :not_found} = err ->
        err

      {:error, :requires_reencryption, _integration} ->
        {:error, :requires_reencryption}
    end
  end

  # ---------------
  # Connection (by id, or probe_integration/2 for the background/health-check struct path)
  # ---------------
  @spec test_connection(pos_integer(), pos_integer()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(user_id, id) when is_integer(user_id) and is_integer(id),
    do: Connection.test_connection(user_id, id)

  @doc """
  Returns a currently-valid OAuth access token for the user's integration,
  refreshing it first if the stored one has expired.

  The public way for tooling outside this domain to talk to a provider's API:
  decryption stays with the schema and the refresh goes through the provider's
  own locked, persisting token path. See
  `Tymeslot.Integrations.Video.AccessToken`.
  """
  @spec access_token(integer(), integer()) :: {:ok, String.t()} | {:error, AccessToken.reason()}
  defdelegate access_token(integration_id, user_id), to: AccessToken, as: :fetch

  @spec probe_integration(VideoIntegrationSchema.t(), keyword()) ::
          {:ok, String.t()} | {:error, any()}
  def probe_integration(%VideoIntegrationSchema{} = integration, opts),
    do: Connection.test_integration(integration, opts)

  # ---------------
  # Meeting room operations
  # ---------------
  @spec create_meeting_room(pos_integer() | nil, keyword()) :: {:ok, map()} | {:error, any()}
  defdelegate create_meeting_room(user_id, opts), to: Rooms

  @spec room_creation_budget_ms(pos_integer() | nil, pos_integer() | nil) :: non_neg_integer()
  defdelegate room_creation_budget_ms(user_id, integration_id), to: Rooms

  @spec create_join_url(map(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, any()}
  defdelegate create_join_url(
                meeting_context,
                participant_name,
                participant_email,
                role,
                meeting_time
              ),
              to: Rooms

  @spec shared_join_url(map(), DateTime.t() | nil) :: {:ok, String.t() | nil} | {:error, any()}
  defdelegate shared_join_url(meeting_context, meeting_time), to: Rooms

  @spec existing_room_context(pos_integer() | nil, keyword()) ::
          {:ok, map()} | {:error, any()}
  defdelegate existing_room_context(user_id, opts), to: Rooms

  @spec time_bound_join_urls?(map()) :: boolean()
  defdelegate time_bound_join_urls?(meeting_context), to: Rooms

  @spec update_meeting_room(pos_integer() | nil, keyword()) :: :ok | {:error, any()}
  defdelegate update_meeting_room(user_id, opts), to: Rooms

  @spec delete_meeting_room(pos_integer() | nil, keyword()) :: :ok | {:error, any()}
  defdelegate delete_meeting_room(user_id, opts), to: Rooms

  # ---------------
  # URL helpers
  # ---------------
  @doc """
  Reads the room id out of a meeting context.
  """
  @spec extract_room_id(map()) :: String.t() | nil
  defdelegate extract_room_id(input), to: Urls

  @doc """
  Extracts the room id from a meeting URL using the named provider's own rules.
  """
  @spec extract_room_id(String.t(), atom() | String.t()) :: String.t() | nil
  defdelegate extract_room_id(meeting_url, provider), to: Urls

  # ---------------
  # OAuth callback
  # ---------------

  @doc """
  Completes a Google Meet, Teams or Zoom OAuth callback and connects the
  integration. See `Tymeslot.Integrations.Video.OAuthCallback.complete/4`.
  """
  @spec complete_oauth(OAuth.provider(), String.t(), String.t(), pos_integer()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, term()}
  defdelegate complete_oauth(provider, code, state, user_id), to: OAuthCallback, as: :complete

  @doc """
  Creates or updates an OAuth video integration from callback token data.
  See `Tymeslot.Integrations.Video.OAuthCallback.match_or_create/6`.
  """
  @spec match_or_create_oauth_integration(
          pos_integer(),
          String.t(),
          String.t(),
          String.t() | nil,
          pos_integer() | nil,
          map()
        ) :: {:ok, VideoIntegrationSchema.t()} | {:error, any()}
  defdelegate match_or_create_oauth_integration(
                user_id,
                provider,
                name,
                provider_account_id,
                integration_id,
                token_attrs
              ),
              to: OAuthCallback,
              as: :match_or_create

  # ---------------
  # OAuth URL generation
  # ---------------
  @spec oauth_authorization_url(pos_integer(), provider()) ::
          {:ok, String.t()} | {:error, String.t()}
  def oauth_authorization_url(user_id, provider) when is_integer(user_id) do
    case ProviderConfig.parse(provider) do
      {:ok, parsed} -> OAuth.authorization_url(parsed, user_id)
      _other -> {:error, "Provider does not support OAuth"}
    end
  end

  @doc """
  Generates an OAuth reconnect URL for an existing integration.
  Passes login_hint and integration_id for targeted re-authorization.
  """
  @spec oauth_reconnect_url(pos_integer(), VideoIntegrationSchema.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def oauth_reconnect_url(user_id, integration) do
    opts = [
      integration_id: integration.id,
      login_hint: integration.provider_account_email
    ]

    case ProviderConfig.parse_known(integration.provider) do
      {:ok, parsed} ->
        if OAuth.supported?(parsed) do
          OAuth.reconnect_url(parsed, user_id, opts)
        else
          {:error, "Provider does not support OAuth reconnection"}
        end

      _other ->
        {:error, "Provider does not support OAuth reconnection"}
    end
  end
end
