defmodule Tymeslot.Integrations.Video do
  @moduledoc """
  UI-agnostic facade for video integration business logic.

  Exposes a cohesive API used by web components without any LiveView/socket coupling.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.EmailScheduler.IntegrationScheduler
  alias Tymeslot.Integrations.Common.OAuth.AccountMatch
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video.AccessToken
  alias Tymeslot.Integrations.Video.AccountKey
  alias Tymeslot.Integrations.Video.AttrsCasting
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Integrations.Video.Disconnect
  alias Tymeslot.Integrations.Video.Discovery
  alias Tymeslot.Integrations.Video.MeetingLinkTemplate
  alias Tymeslot.Integrations.Video.OAuth
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.Reconnect
  alias Tymeslot.Integrations.Video.Rooms
  alias Tymeslot.Integrations.Video.Update
  alias Tymeslot.Integrations.Video.Urls
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @behaviour Tymeslot.Security.EncryptedStorage

  require Logger

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
       VideoIntegrationSchema.encrypted_credential_fields()}

  # ---------------
  # Read
  # ---------------
  @spec list_integrations(pos_integer()) :: list()
  def list_integrations(user_id) when is_integer(user_id) do
    VideoIntegrationQueries.list_all_for_user(user_id)
  end

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
    VideoIntegrationQueries.get_for_user(id, user_id)
  end

  @doc """
  Entry point for the "credentials no longer decrypt" path, used by any
  worker or caller that receives `{:error, :requires_reencryption, integration}`
  from `VideoIntegrationQueries.get/1` or `VideoIntegrationQueries.get_for_user/2`.

  Pass `cause: cause` (see `t:Tymeslot.Integrations.Shared.ReauthHandling.cause/0`)
  when the integration needs reconnecting for a different reason, so the message
  recorded on `sync_error` describes what actually failed.

  Returns an Oban return value: `{:discard, _}` on success (retrying won't
  recover the credentials), or `{:error, _}` if the flag couldn't be persisted —
  which causes Oban to retry the job and take another shot at recording the flag.
  """
  @spec handle_reauth_required(VideoIntegrationSchema.t(), keyword()) ::
          {:discard, String.t()} | {:error, String.t()}
  def handle_reauth_required(%VideoIntegrationSchema{} = integration, opts \\ []) do
    case flag_for_reauth(integration, opts) do
      :ok -> {:discard, "Credentials require reauthentication"}
      {:error, _changeset} -> {:error, "Failed to flag integration for reauth"}
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
  def fetch_integration_for_user(id, user_id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :requires_reencryption, stale} ->
        flag_for_reauth(stale)
        {:error, :not_found}
    end
  end

  # Shared helper: delegates to ReauthHandling.flag/2 with video-specific opts.
  # `mark_needs_reauth` is wired to `flag_and_notify/2` rather than the bare
  # DB write, so that every path ending in "the owner has to reconnect", this
  # one included and not just the provider-level 401 handling in
  # `OAuthTokenManager`, sends the reauth email on the false to true
  # transition. Keeping this symmetrical with `CalendarManagement` is
  # deliberate: the two used to disagree on which paths notified.
  defp flag_for_reauth(integration, opts \\ []) do
    ReauthHandling.flag(
      integration,
      Keyword.merge(
        [mark_needs_reauth: &flag_and_notify/2, log_prefix: "Video"],
        opts
      )
    )
  end

  @doc """
  Marks a video integration `needs_reauth` and emails the owner on the
  false → true transition. Shared by `flag_for_reauth/2` and by
  `OAuthTokenManager`'s provider-level 401 handling, so the two paths cannot
  drift on whether reconnecting is announced.

  Re-flagging an integration already awaiting reconnection is not news: the
  owner has already been told, and the scheduler's uniqueness window is a
  backstop for that, not the place to decide it.
  """
  @spec flag_and_notify(VideoIntegrationSchema.t(), String.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def flag_and_notify(%{needs_reauth: true} = integration, message),
    do: VideoIntegrationQueries.mark_needs_reauth(integration, message)

  def flag_and_notify(integration, message) do
    with {:ok, updated} = result <-
           VideoIntegrationQueries.mark_needs_reauth(integration, message) do
      IntegrationScheduler.schedule_integration_reauth_notification(
        %{id: updated.user_id},
        updated,
        :video
      )

      result
    end
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
    provider =
      case ProviderConfig.parse(provider) do
        {:ok, atom} -> atom
        {:error, :unknown} -> :unknown
      end

    attrs = AttrsCasting.atomize_known_attrs(attrs)

    # Enforce provider in attrs consistently as string for DB layer
    attrs = Map.put(Map.put(attrs, :user_id, user_id), :provider, to_string(provider))

    provider
    |> do_create_integration(attrs)
    |> AccountKey.refuse_taken_key()
  end

  # `create_integration/3` has already atomised every key by the time these
  # clauses run, so the attrs are read one way here.
  defp do_create_integration(:mirotalk, attrs) do
    base_url = attrs[:base_url]
    attrs = Map.put(attrs, :provider_account_id, AccountKey.from_url(base_url))

    # Pre-test the connection prior to creation for better UX
    config = %{
      api_key: attrs[:api_key],
      base_url: base_url
    }

    # Order matters, and the probe goes last. Everything above it is decided
    # in-process, while the probe is an outbound request to an address the
    # organiser typed, which is the thing the connection-test bucket exists to
    # meter. Probing first meant a re-added server, or a submission the
    # changeset was always going to reject, spent a token on a refusal that
    # never left the machine, and the organiser was then told they had run too
    # many connection tests after pressing "Add".
    with :ok <- check_no_duplicate(attrs),
         :ok <- VideoIntegrationSchema.validate_new(attrs),
         {:ok, _msg} <- probe_mirotalk_connection(config, attrs[:user_id]) do
      VideoIntegrationQueries.create(attrs)
    end
  end

  defp do_create_integration(:custom, attrs) do
    attrs = Map.put(attrs, :provider_account_id, AccountKey.from_url(attrs[:custom_meeting_url]))

    with :ok <- check_no_duplicate(attrs) do
      VideoIntegrationQueries.create(attrs)
    end
  end

  # kMeet has exactly one host, so there is no account to key on. Leaving
  # `provider_account_id` nil files the row under
  # `unique_active_video_null_account_per_user`, which is precisely the
  # "one active kMeet per user" rule we want. Like every provider without an
  # account id, the rule covers active rows only, so an inactive kMeet row does
  # not block a new one. The index refusal is translated here, so callers learn
  # the provider is already connected without knowing the index exists.
  defp do_create_integration(:kmeet, attrs) do
    case VideoIntegrationQueries.create(attrs) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if provider_already_connected?(changeset),
          do: {:error, :provider_already_connected},
          else: error

      result ->
        result
    end
  end

  # The server URL is the dedup key (`AccountKey`), so one user can connect
  # several Jitsi servers but not the same one twice. The config is validated before
  # anything is saved: a half-filled credential pair or a short secret would
  # otherwise only surface when a later booking fails to get its video link.
  defp do_create_integration(:jitsi, attrs) do
    attrs = Map.put(attrs, :provider_account_id, AccountKey.from_url(attrs[:base_url]))

    with :ok <- JitsiProvider.validate_config(attrs),
         :ok <- check_no_duplicate(attrs) do
      VideoIntegrationQueries.create(attrs)
    end
  end

  # Keyed on server and login together, as the CalDAV integrations are, so one
  # person can connect two accounts on the same Nextcloud but not one account
  # twice. The duplicate check comes first, so a repeat never spends a login
  # attempt against the server; the connection probe then validates the config
  # and proves the app password and a recent enough Talk before anything is
  # saved.
  defp do_create_integration(:nextcloud_talk, attrs) do
    attrs = NextcloudTalkProvider.account_attrs(attrs)

    with :ok <- check_no_duplicate(attrs),
         {:ok, _message} <-
           Connection.probe(
             :nextcloud_talk,
             Map.take(attrs, [:base_url, :client_id, :client_secret]),
             {:user, attrs[:user_id]}
           ) do
      VideoIntegrationQueries.create(attrs)
    end
  end

  # OAuth providers are created after OAuth callback normally; allow manual create only for none
  defp do_create_integration(provider, attrs)
       when provider in [:google_meet, :teams, :zoom, :none] do
    VideoIntegrationQueries.create(attrs)
  end

  defp do_create_integration(_unknown, _attrs), do: {:error, :unknown_provider}

  # Structural validation is never rate-limited; only the network probe is,
  # charged to the user submitting the setup form. Both happen inside
  # `Connection.probe/3` — the same choke point
  # `Video.Connection.test_integration/2` uses — rather than reimplementing
  # the validation, bucket lookup, and charge here.
  defp probe_mirotalk_connection(config, user_id) do
    Connection.probe(:mirotalk, config, {:user, user_id})
  end

  # Active and inactive integrations alike, so no two rows share an account.
  defp check_no_duplicate(%{user_id: user_id, provider: provider} = attrs),
    do: AccountKey.check_free(user_id, provider, attrs[:provider_account_id], nil)

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
  @spec toggle_integration(pos_integer(), pos_integer()) :: {:ok, any()} | {:error, any()}
  def toggle_integration(user_id, id) when is_integer(user_id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
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
  # Provider discovery helpers
  # ---------------
  @spec default_provider() :: atom()
  def default_provider, do: Discovery.default_provider()

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
  Reads the room id out of a meeting context, or guesses it from a bare URL.

  The URL form is a best-effort guess at which provider issued the link, so a
  caller that holds an integration must use `extract_room_id/2` instead. See
  `Tymeslot.Integrations.Video.Urls.extract_room_id/1`.
  """
  @spec extract_room_id(String.t() | map()) :: String.t() | nil
  defdelegate extract_room_id(input), to: Urls

  @doc """
  Extracts the room id from a meeting URL using the named provider's own rules.
  """
  @spec extract_room_id(String.t(), atom() | String.t()) :: String.t() | nil
  defdelegate extract_room_id(meeting_url, provider), to: Urls

  # ---------------
  # OAuth create-or-update
  # ---------------

  @doc """
  Creates or updates an OAuth video integration from callback token data.

  Handles three scenarios:
  1. Re-authorization of a specific integration (integration_id present)
  2. New connection with a known account (provider_account_id present)
  3. Legacy fallback — match by user + provider

  An OAuth callback proves the grant, so every update of an existing row goes
  through `Tymeslot.Integrations.Video.Reconnect`, which catches the rooms up
  on what they missed while the integration needed reconnecting.
  """
  @spec match_or_create_oauth_integration(
          pos_integer(),
          String.t(),
          String.t(),
          String.t() | nil,
          pos_integer() | nil,
          map()
        ) :: {:ok, VideoIntegrationSchema.t()} | {:error, any()}
  def match_or_create_oauth_integration(
        user_id,
        provider,
        name,
        provider_account_id,
        integration_id,
        token_attrs
      ) do
    cond do
      integration_id ->
        reauthorize_existing(user_id, integration_id, provider_account_id, token_attrs)

      is_binary(provider_account_id) ->
        match_or_create_by_account(user_id, provider, name, provider_account_id, token_attrs)

      true ->
        fallback_match_or_create(user_id, provider, name, token_attrs)
    end
  end

  defp reauthorize_existing(user_id, integration_id, provider_account_id, token_attrs) do
    case VideoIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok, existing} ->
        AccountMatch.verify_account_match(existing, provider_account_id, fn ->
          Reconnect.save(existing, token_attrs)
        end)

      {:error, :not_found} ->
        {:error, "Integration not found"}

      {:error, :requires_reencryption, existing} ->
        # Credentials are stale but the user is reconnecting — allow the update
        # so fresh credentials replace the undecryptable ones.
        AccountMatch.verify_account_match(existing, provider_account_id, fn ->
          Reconnect.save(existing, token_attrs)
        end)
    end
  end

  defp match_or_create_by_account(user_id, provider, name, provider_account_id, token_attrs) do
    case VideoIntegrationQueries.get_by_account_for_user(user_id, provider, provider_account_id) do
      {:ok, existing} ->
        Reconnect.save(existing, token_attrs)

      {:error, :not_found} ->
        reactivate_or_create_video(user_id, provider, name, provider_account_id, token_attrs)
    end
  end

  defp reactivate_or_create_video(user_id, provider, name, provider_account_id, token_attrs) do
    reactivation_attrs = Map.put(token_attrs, :is_active, true)
    create_attrs = Map.merge(token_attrs, %{user_id: user_id, name: name, provider: provider})

    AccountMatch.find_or_create_with_reactivation(
      fn ->
        VideoIntegrationQueries.get_any_by_account_for_user(
          user_id,
          provider,
          provider_account_id
        )
      end,
      fn existing -> Reconnect.save(existing, reactivation_attrs) end,
      fn ->
        AccountMatch.create_with_race_protection(
          fn -> VideoIntegrationQueries.create(create_attrs) end,
          fn ->
            VideoIntegrationQueries.get_by_account_for_user(
              user_id,
              provider,
              provider_account_id
            )
          end,
          fn existing -> Reconnect.save(existing, token_attrs) end
        )
      end
    )
  end

  defp fallback_match_or_create(user_id, provider, name, token_attrs) do
    Logger.warning(
      "OAuth callback missing provider_account_id — using legacy per-provider match",
      user_id: user_id,
      provider: provider
    )

    case VideoIntegrationQueries.get_by_provider_for_user(user_id, provider) do
      {:ok, _existing} ->
        # User already has integration(s) for this provider but we can't identify
        # which account this callback belongs to. Reject to avoid silently overwriting.
        {:error,
         dgettext(
           "dashboard_integrations",
           "Could not identify your account. Please try again. If the problem persists, remove and re-add the integration."
         )}

      {:error, :not_found} ->
        VideoIntegrationQueries.create(
          Map.merge(token_attrs, %{user_id: user_id, name: name, provider: provider})
        )
    end
  end

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
