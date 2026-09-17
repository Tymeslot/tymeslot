defmodule Tymeslot.Integrations.Video.Update do
  @moduledoc """
  Updates a video integration from its owner's edit.

  An edit arrives from a form whose credential inputs start blank, since a
  stored secret is never sent back to the browser. A blank credential
  therefore means "keep the stored one", and removing credentials has to be
  asked for explicitly. Supplying a credential counts as reconnecting, so it
  also clears `needs_reauth`.

  A Nextcloud Talk edit is proven against the server, as a new integration
  is, but only when its server, login name or app password actually changes.
  Such a proven edit is the reconnect, so it clears `needs_reauth`; an edit
  that is not proven never does. The stored app password is never sent to a
  different server (another scheme, host or port): moving the integration
  there means entering the app password again, so a moved Nextcloud is
  reconnected by entering its new address together with the app password. A
  new subfolder on the same server keeps the stored one.

  A reschedule made while the integration needed reconnecting could not be
  sent to its rooms, so a proven reconnect sends every upcoming meeting's room
  its current time and name again. An unproven clear never does: those
  updates would go out with credentials nothing has shown to work, and on a
  self-hosted server each refusal counts against its brute-force protection.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Plug.Crypto
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Video.AttrsCasting
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Workers.VideoSyncWorker

  require Logger

  # What a Jitsi or Nextcloud Talk integration connects with: a server of the
  # organiser's choosing and a client id and secret. Jitsi's provider validates
  # them, since its credentials are optional and the changeset cannot enforce
  # the pair or the secret length; a Talk edit is proven with them.
  @client_credential_fields [:client_id, :client_secret]
  @server_config_fields [:base_url | @client_credential_fields]

  # What a Talk edit can save: the account key follows from the server and
  # login name.
  @talk_saved_fields [:provider_account_id | @server_config_fields]

  # How many upcoming meetings a proven reconnect re-sends to their rooms, far
  # more than one integration holds in practice.
  @resync_limit 500

  @doc """
  Updates the integration `id` owned by `user_id`.

  A blank credential in `attrs` keeps the stored one. To switch off a Jitsi
  integration's token authentication, pass `remove_token_authentication:
  true`: both stored credentials are removed, and any submitted alongside
  the flag are ignored. Other providers ignore the flag.
  """
  @spec run(pos_integer(), pos_integer(), %{(String.t() | atom()) => term()}) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, any()}
  def run(user_id, id, attrs)
      when is_integer(user_id) and is_integer(id) and is_map(attrs) do
    attrs = AttrsCasting.atomize_known_attrs(attrs)

    case VideoIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} ->
        attrs = effective_changes(integration, attrs)

        with :ok <- validate_update(integration, attrs) do
          save_update(integration, attrs)
        end

      {:error, :not_found} = err ->
        err

      {:error, :requires_reencryption, _integration} ->
        {:error, :requires_reencryption}
    end
  end

  # The Talk edit dialog submits the server and login name it opened with and
  # whatever was typed into the app password field, so a rename carries all
  # three. A blank login name or app password keeps the stored one, as a blank
  # Jitsi credential does; a blank server address is kept, for the provider to
  # refuse. Only a value that differs from the stored one after the provider's
  # own normalising is kept as a change, together with the account key it implies,
  # and a submitted account key is never taken as given. Dropping the rest is
  # what keeps a rename or an unchanged resubmission from contacting the server
  # and from clearing a reconnect flag no new credential earned. The one
  # exception is an app password entered with a move to a different server:
  # it is kept even when it matches the stored one, since entering it is what
  # allows it to be sent there.
  defp effective_changes(%VideoIntegrationSchema{provider: "nextcloud_talk"} = integration, attrs) do
    stored =
      integration |> Map.take(@server_config_fields) |> NextcloudTalkProvider.account_attrs()

    submitted =
      attrs
      |> Map.take(@server_config_fields)
      |> Map.reject(fn {field, value} -> field in @client_credential_fields and blank?(value) end)

    updated = stored |> Map.merge(submitted) |> NextcloudTalkProvider.account_attrs()

    keep_app_password? =
      Map.has_key?(submitted, :client_secret) and
        not same_origin?(updated.base_url, stored.base_url)

    changes =
      updated
      |> Map.take(@talk_saved_fields)
      |> Map.reject(fn
        {:client_secret, _value} when keep_app_password? -> false
        {field, value} -> unchanged?(field, value, Map.fetch!(stored, field))
      end)

    attrs |> Map.drop(@talk_saved_fields) |> Map.merge(changes)
  end

  defp effective_changes(_integration, attrs), do: attrs

  defp unchanged?(:client_secret, submitted, stored) when is_binary(submitted),
    do: same_credential?(submitted, stored)

  defp unchanged?(:client_secret, _submitted, _stored), do: false
  defp unchanged?(_field, submitted, stored), do: submitted == stored

  defp save_update(
         %VideoIntegrationSchema{provider: "jitsi"} = integration,
         %{remove_token_authentication: true} = attrs
       ) do
    VideoIntegrationQueries.update_removing_credentials(
      integration,
      Map.drop(attrs, @client_credential_fields),
      @client_credential_fields
    )
  end

  # A Talk edit that still carries a server, login name or app password has
  # been proven against the server, and that proof is the reconnect: it clears
  # `needs_reauth` whichever of them changed, as when Nextcloud moved to a new
  # address, the old one refused the app password, and the organiser entered
  # the new address together with the app password (which a different server
  # requires).
  defp save_update(%VideoIntegrationSchema{provider: "nextcloud_talk"} = integration, attrs) do
    if talk_connection_changed?(attrs) do
      with {:ok, updated} = ok <- update_with_credentials(integration, attrs) do
        resync_rooms_after_proven_reconnect(integration, updated)
        ok
      end
    else
      VideoIntegrationQueries.update(integration, attrs)
    end
  end

  defp save_update(integration, attrs) do
    if credentials_changed?(integration, attrs) do
      update_with_credentials(integration, attrs)
    else
      VideoIntegrationQueries.update(integration, attrs)
    end
  end

  # An edit to a Jitsi server URL or credentials is validated exactly as a
  # create is, against the config the row will hold once saved. A nil, empty
  # or whitespace-only credential in `attrs` leaves the stored one in place
  # (`cast/3` trims it to nil, and the changeset never overwrites an encrypted
  # credential with nothing), so the stored value stands in for it here too; a
  # blank server URL is refused by the changeset either way. Removing token
  # authentication validates the config as it will be, without credentials. An
  # update touching none of these fields, such as a rename, is not
  # re-validated, so it cannot be refused over a value it leaves alone.
  defp validate_update(
         %VideoIntegrationSchema{provider: "jitsi"} = integration,
         %{remove_token_authentication: true} = attrs
       ) do
    integration
    |> jitsi_config_after_update(Map.drop(attrs, @client_credential_fields))
    |> Map.merge(Map.new(@client_credential_fields, &{&1, nil}))
    |> JitsiProvider.validate_config()
  end

  defp validate_update(%VideoIntegrationSchema{provider: "jitsi"} = integration, attrs) do
    if Enum.any?(@server_config_fields, &Map.has_key?(attrs, &1)) do
      integration
      |> jitsi_config_after_update(attrs)
      |> JitsiProvider.validate_config()
    else
      :ok
    end
  end

  # A changed server, login name or app password is proven against the server
  # before it is saved, as on creation, with the configuration the row will then
  # hold. As on creation, an account already connected comes first, so moving
  # onto it spends no login attempt. `Connection.probe/3` validates the
  # configuration before any request, so a blank server address is refused
  # without one, and a refusal comes back worded as the connection test words
  # it. The probe carries no integration id, so a refused new app password does
  # not flag the row. The configuration is validated first, so an unusable
  # server address is refused with its own message before the organiser is
  # asked for an app password it could not be used with anyway.
  defp validate_update(%VideoIntegrationSchema{provider: "nextcloud_talk"} = integration, attrs) do
    if talk_connection_changed?(attrs) do
      config =
        integration
        |> Map.take(@server_config_fields)
        |> Map.merge(Map.take(attrs, @server_config_fields))

      with :ok <- NextcloudTalkProvider.validate_config(config),
           :ok <- check_app_password_entered(integration, attrs),
           :ok <- check_account_free(integration, attrs),
           {:ok, _message} <-
             Connection.probe(:nextcloud_talk, config, {:user, integration.user_id}),
           do: :ok
    else
      :ok
    end
  end

  defp validate_update(_integration, _attrs), do: :ok

  defp talk_connection_changed?(attrs),
    do: Enum.any?(@server_config_fields, &Map.has_key?(attrs, &1))

  # The stored app password may have been copied from a calendar connection or
  # typed for this server only, so it goes to a different server only when the
  # organiser enters it again. `effective_changes/2` keeps an app password
  # entered with such a move, so its absence here means none was entered.
  defp check_app_password_entered(integration, %{base_url: base_url} = attrs)
       when not is_map_key(attrs, :client_secret) do
    if same_origin?(base_url, integration.base_url) do
      :ok
    else
      {:error,
       {:secret_required,
        dgettext(
          "dashboard_integrations",
          "Enter the app password again to connect to a different server."
        )}}
    end
  end

  defp check_app_password_entered(_integration, _attrs), do: :ok

  # Scheme, host and port: what decides which server receives a request. A
  # port left out is the scheme's default, so the same server written with and
  # without it is one origin.
  defp same_origin?(url, other_url), do: origin(url) == origin(other_url)

  defp origin(url) when is_binary(url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    {scheme && String.downcase(scheme), host && String.downcase(host), port}
  end

  defp origin(_url), do: nil

  # Active or not, as creation checks, so no two rows share an account key.
  defp check_account_free(integration, %{provider_account_id: account_id}) do
    case VideoIntegrationQueries.get_any_by_account_for_user(
           integration.user_id,
           integration.provider,
           account_id
         ) do
      {:ok, %VideoIntegrationSchema{id: id}} when id != integration.id ->
        {:error, :duplicate_integration}

      _free_or_this_integration ->
        :ok
    end
  end

  defp check_account_free(_integration, _attrs), do: :ok

  defp jitsi_config_after_update(integration, attrs) do
    integration
    |> Map.take(@server_config_fields)
    |> Map.merge(Map.take(attrs, @server_config_fields), fn _field, stored, new ->
      if blank?(new), do: stored, else: new
    end)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)

  defp update_with_credentials(integration, attrs) do
    with {:ok, updated} = ok <- VideoIntegrationQueries.update_credentials(integration, attrs) do
      HealthCheck.mark_user_recovered(:video, updated.id)
      ok
    end
  end

  # Only for an integration that needed reconnecting, whose reschedules were
  # dropped while it did, and only once the saved row no longer needs it. The
  # jobs are queued after the write has committed, so each one reads the
  # reconnected integration. Re-sending a room its unchanged time and name is
  # harmless, which is what lets every upcoming room be queued rather than only
  # those that moved. A job still waiting to run for a meeting already covers
  # it, since it reads the meeting when it runs.
  defp resync_rooms_after_proven_reconnect(
         %VideoIntegrationSchema{needs_reauth: true, id: id, provider: provider},
         %VideoIntegrationSchema{needs_reauth: false}
       ) do
    if ProviderConfig.rooms_updated_on_reschedule?(provider) do
      id
      |> MeetingListQueries.list_upcoming_ids_with_video_room_for_integration(
        DateTime.utc_now(),
        @resync_limit
      )
      |> Enum.each(&enqueue_room_update(&1, id))
    end

    :ok
  end

  defp resync_rooms_after_proven_reconnect(_before, _after), do: :ok

  defp enqueue_room_update(meeting_id, integration_id) do
    case VideoSyncWorker.enqueue(meeting_id, "update") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to queue a room update after the integration was reconnected",
          meeting_id: meeting_id,
          integration_id: integration_id,
          reason: inspect(reason)
        )
    end
  end

  # A credential counts as supplied only when it would change what is stored.
  # The edit dialog fills in the stored App ID, so resubmitting it unchanged
  # is not a reconnect and must not clear `needs_reauth`; neither is a blank
  # value, which keeps the stored one. Callers supply the virtual field names
  # (`:api_key`), never the encrypted ones, which only exist after
  # `encrypt_credentials/1` runs inside the changeset.
  defp credentials_changed?(integration, attrs) do
    Enum.any?(VideoIntegrationSchema.credential_fields(), fn field ->
      case Map.fetch(attrs, field) do
        {:ok, value} when is_binary(value) ->
          not blank?(value) and not same_credential?(value, Map.get(integration, field))

        _absent_or_not_text ->
          false
      end
    end)
  end

  # Constant-time, so comparing against a stored secret leaks nothing through
  # timing; neither value is ever logged or returned.
  defp same_credential?(submitted, stored) when is_binary(stored),
    do: Crypto.secure_compare(String.trim(submitted), stored)

  defp same_credential?(_submitted, _stored), do: false
end
