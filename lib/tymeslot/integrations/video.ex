defmodule Tymeslot.Integrations.Video do
  @moduledoc """
  UI-agnostic facade for video integration business logic.

  Exposes a cohesive API used by web components without any LiveView/socket coupling.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Common.OAuth.AccountMatch
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video.AttrsCasting
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Integrations.Video.Disconnect
  alias Tymeslot.Integrations.Video.Discovery
  alias Tymeslot.Integrations.Video.OAuth
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Rooms
  alias Tymeslot.Integrations.Video.Urls
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @behaviour Tymeslot.Security.EncryptedStorage

  require Logger

  @type provider :: :google_meet | :teams | :zoom | :mirotalk | :custom | :none | String.t()

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

  @doc """
  Gets a single video integration by ID for a specific user.
  """
  @spec get_integration(pos_integer(), pos_integer()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
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
  Fetches a video integration by ID, collapsing the
  `{:error, :requires_reencryption, integration}` arm into `{:error, :not_found}`
  after silently flagging the integration for reauthentication.

  Use this in non-Oban callers that only care about the two-outcome
  `{:ok, _} | {:error, :not_found}` shape.
  """
  @spec fetch_integration(integer()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, :not_found}
  def fetch_integration(id) do
    case VideoIntegrationQueries.get(id) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :requires_reencryption, stale} ->
        flag_for_reauth(stale)
        {:error, :not_found}
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
  defp flag_for_reauth(integration, opts \\ []) do
    ReauthHandling.flag(
      integration,
      Keyword.merge(
        [mark_needs_reauth: &VideoIntegrationQueries.mark_needs_reauth/2, log_prefix: "Video"],
        opts
      )
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
    provider =
      case ProviderConfig.parse(provider) do
        {:ok, atom} -> atom
        {:error, :unknown} -> :unknown
      end

    attrs = AttrsCasting.atomize_known_attrs(attrs)

    # Enforce provider in attrs consistently as string for DB layer
    attrs = Map.put(Map.put(attrs, :user_id, user_id), :provider, to_string(provider))

    do_create_integration(provider, attrs)
  end

  # `create_integration/3` has already atomised every key by the time these
  # clauses run, so the attrs are read one way here.
  defp do_create_integration(:mirotalk, attrs) do
    # Set provider_account_id for dedup
    base_url = attrs[:base_url]
    attrs = Map.put(attrs, :provider_account_id, base_url)

    # Pre-test the connection prior to creation for better UX
    config = %{
      api_key: attrs[:api_key],
      base_url: base_url
    }

    with {:ok, _msg} <- probe_mirotalk_connection(config, attrs[:user_id]),
         :ok <- check_no_duplicate(attrs) do
      VideoIntegrationQueries.create(attrs)
    end
  end

  defp do_create_integration(:custom, attrs) do
    # Set provider_account_id from custom_meeting_url for dedup
    custom_url = attrs[:custom_meeting_url]
    attrs = Map.put(attrs, :provider_account_id, custom_url)

    with :ok <- check_no_duplicate(attrs) do
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

  defp check_no_duplicate(%{
         user_id: user_id,
         provider: provider,
         provider_account_id: account_id
       })
       when is_binary(account_id) and account_id != "" do
    # Check both active and inactive integrations to prevent duplicate rows
    case VideoIntegrationQueries.get_any_by_account_for_user(
           user_id,
           to_string(provider),
           account_id
         ) do
      {:ok, _existing} -> {:error, :duplicate_integration}
      {:error, :not_found} -> :ok
    end
  end

  defp check_no_duplicate(_attrs), do: :ok

  # ---------------
  # Update
  # ---------------
  @spec update_integration(pos_integer(), pos_integer(), %{atom() => term()}) ::
          {:ok, any()} | {:error, any()}
  def update_integration(user_id, id, attrs) when is_integer(user_id) and is_integer(id) do
    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} ->
        case VideoIntegrationQueries.update(integration, attrs) do
          {:ok, updated} = ok ->
            if credentials_in_attrs?(attrs) do
              HealthCheck.mark_user_recovered(:video, updated.id)
            end

            ok

          err ->
            err
        end

      {:error, :not_found} = err ->
        err

      {:error, :requires_reencryption, _integration} ->
        {:error, :requires_reencryption}
    end
  end

  defp credentials_in_attrs?(attrs) when is_map(attrs) do
    fields = VideoIntegrationSchema.encrypted_credential_fields()

    Enum.any?(fields, fn f -> Map.has_key?(attrs, f) or Map.has_key?(attrs, Atom.to_string(f)) end)
  end

  # ---------------
  # Delete
  # ---------------
  @doc """
  Disconnects a video integration.

  With `delete_rooms: true` the integration is soft-deleted and a background job
  deletes the provider-side rooms of the user's upcoming bookings before purging
  the row. Without it the row goes immediately and existing rooms are left
  running, so join URLs already sitting in attendees' calendar invites keep
  working.
  """
  @spec delete_integration(pos_integer(), pos_integer(), keyword()) ::
          {:ok, :deleted | :cleanup_scheduled} | {:error, any()}
  defdelegate delete_integration(user_id, id, opts \\ []), to: Disconnect, as: :run

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
  @spec list_available_providers() :: list()
  def list_available_providers, do: Discovery.list_available_providers()

  @spec default_provider() :: atom()
  def default_provider, do: Discovery.default_provider()

  # ---------------
  # Connection (by id, or probe_integration/2 for the background/health-check struct path)
  # ---------------
  @spec test_connection(pos_integer(), pos_integer()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(user_id, id) when is_integer(user_id) and is_integer(id),
    do: Connection.test_connection(user_id, id)

  @spec probe_integration(VideoIntegrationSchema.t(), keyword()) ::
          {:ok, String.t()} | {:error, any()}
  def probe_integration(%VideoIntegrationSchema{} = integration, opts),
    do: Connection.test_integration(integration, opts)

  # ---------------
  # Meeting room operations
  # ---------------
  @spec create_meeting_room(pos_integer() | nil, keyword()) :: {:ok, map()} | {:error, any()}
  defdelegate create_meeting_room(user_id \\ nil, opts \\ []), to: Rooms

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

  @spec handle_meeting_event(map(), atom(), map()) :: :ok | {:error, any()}
  defdelegate handle_meeting_event(meeting_context, event, additional_data \\ %{}), to: Rooms

  @spec update_meeting_room(pos_integer() | nil, keyword()) :: :ok | {:error, any()}
  defdelegate update_meeting_room(user_id, opts), to: Rooms

  @spec delete_meeting_room(pos_integer() | nil, keyword()) :: :ok | {:error, any()}
  defdelegate delete_meeting_room(user_id, opts), to: Rooms

  @spec generate_meeting_metadata(map()) :: map()
  defdelegate generate_meeting_metadata(meeting_context), to: Rooms

  # ---------------
  # URL helpers
  # ---------------
  @spec extract_room_id(String.t() | map()) :: String.t() | nil
  defdelegate extract_room_id(input), to: Urls

  @spec valid_meeting_url?(String.t()) :: boolean()
  defdelegate valid_meeting_url?(url), to: Urls

  # ---------------
  # OAuth create-or-update
  # ---------------

  @doc """
  Creates or updates an OAuth video integration from callback token data.

  Handles three scenarios:
  1. Re-authorization of a specific integration (integration_id present)
  2. New connection with a known account (provider_account_id present)
  3. Legacy fallback — match by user + provider
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
          VideoIntegrationQueries.update(existing, token_attrs)
        end)

      {:error, :not_found} ->
        {:error, "Integration not found"}

      {:error, :requires_reencryption, existing} ->
        # Credentials are stale but the user is reconnecting — allow the update
        # so fresh credentials replace the undecryptable ones.
        AccountMatch.verify_account_match(existing, provider_account_id, fn ->
          VideoIntegrationQueries.update(existing, token_attrs)
        end)
    end
  end

  defp match_or_create_by_account(user_id, provider, name, provider_account_id, token_attrs) do
    case VideoIntegrationQueries.get_by_account_for_user(user_id, provider, provider_account_id) do
      {:ok, existing} ->
        VideoIntegrationQueries.update(existing, token_attrs)

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
      fn existing -> VideoIntegrationQueries.update(existing, reactivation_attrs) end,
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
          fn existing -> VideoIntegrationQueries.update(existing, token_attrs) end
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
