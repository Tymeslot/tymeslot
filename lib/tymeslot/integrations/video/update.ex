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
  """

  alias Plug.Crypto
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Video.AttrsCasting
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  # What a Jitsi integration's provider validates. Its credentials are
  # optional, so the changeset cannot enforce the pair or the secret length.
  @jitsi_credential_fields [:client_id, :client_secret]
  @jitsi_config_fields [:base_url | @jitsi_credential_fields]

  # What a Nextcloud Talk integration signs in with, and what an edit to it
  # can save: the account key follows from the server and login name.
  @talk_credential_fields [:client_id, :client_secret]
  @talk_config_fields [:base_url | @talk_credential_fields]
  @talk_saved_fields [:provider_account_id | @talk_config_fields]

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
  # own trimming is kept as a change, together with the account key it implies,
  # and a submitted account key is never taken as given. Dropping the rest is
  # what keeps a rename or an unchanged resubmission from contacting the server
  # and from clearing a reconnect flag no new credential earned.
  defp effective_changes(%VideoIntegrationSchema{provider: "nextcloud_talk"} = integration, attrs) do
    stored = integration |> Map.take(@talk_config_fields) |> NextcloudTalkProvider.account_attrs()

    submitted =
      attrs
      |> Map.take(@talk_config_fields)
      |> Map.reject(fn {field, value} -> field in @talk_credential_fields and blank?(value) end)

    changes =
      stored
      |> Map.merge(submitted)
      |> NextcloudTalkProvider.account_attrs()
      |> Map.take(@talk_saved_fields)
      |> Map.reject(fn {field, value} -> unchanged?(field, value, Map.fetch!(stored, field)) end)

    attrs |> Map.drop(@talk_saved_fields) |> Map.merge(changes)
  end

  defp effective_changes(_integration, attrs), do: attrs

  defp unchanged?(:client_secret, submitted, stored), do: same_credential?(submitted, stored)
  defp unchanged?(_field, submitted, stored), do: submitted == stored

  defp save_update(
         %VideoIntegrationSchema{provider: "jitsi"} = integration,
         %{remove_token_authentication: true} = attrs
       ) do
    VideoIntegrationQueries.update_removing_credentials(
      integration,
      Map.drop(attrs, @jitsi_credential_fields),
      @jitsi_credential_fields
    )
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
    |> jitsi_config_after_update(Map.drop(attrs, @jitsi_credential_fields))
    |> Map.merge(Map.new(@jitsi_credential_fields, &{&1, nil}))
    |> JitsiProvider.validate_config()
  end

  defp validate_update(%VideoIntegrationSchema{provider: "jitsi"} = integration, attrs) do
    if Enum.any?(@jitsi_config_fields, &Map.has_key?(attrs, &1)) do
      integration
      |> jitsi_config_after_update(attrs)
      |> JitsiProvider.validate_config()
    else
      :ok
    end
  end

  # A changed server, login name or app password is proven against the server
  # before it is saved, as on creation, with the configuration the row will then
  # hold. `Connection.probe/3` validates that configuration first, so a blank
  # server address is refused without a request, and a refusal comes back
  # worded as the connection test words it. The probe carries no integration id,
  # so a refused new app password does not flag the row again.
  defp validate_update(%VideoIntegrationSchema{provider: "nextcloud_talk"} = integration, attrs) do
    if Enum.any?(@talk_config_fields, &Map.has_key?(attrs, &1)) do
      config =
        integration
        |> Map.take(@talk_config_fields)
        |> Map.merge(Map.take(attrs, @talk_config_fields))

      with {:ok, _message} <-
             Connection.probe(:nextcloud_talk, config, {:user, integration.user_id}),
           do: :ok
    else
      :ok
    end
  end

  defp validate_update(_integration, _attrs), do: :ok

  defp jitsi_config_after_update(integration, attrs) do
    integration
    |> Map.take(@jitsi_config_fields)
    |> Map.merge(Map.take(attrs, @jitsi_config_fields), fn _field, stored, new ->
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
