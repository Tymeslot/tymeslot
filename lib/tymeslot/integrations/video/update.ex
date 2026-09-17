defmodule Tymeslot.Integrations.Video.Update do
  @moduledoc """
  Updates a video integration from its owner's edit.

  An edit arrives from a form whose credential inputs start blank, since a
  stored secret is never sent back to the browser. A blank credential
  therefore means "keep the stored one", and removing credentials has to be
  asked for explicitly. Supplying a credential counts as reconnecting, so it
  also clears `needs_reauth`.
  """

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Video.AttrsCasting
  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  # What a Jitsi integration's provider validates. Its credentials are
  # optional, so the changeset cannot enforce the pair or the secret length.
  @jitsi_credential_fields [:client_id, :client_secret]
  @jitsi_config_fields [:base_url | @jitsi_credential_fields]

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
        with :ok <- validate_update(integration, attrs) do
          save_update(integration, attrs)
        end

      {:error, :not_found} = err ->
        err

      {:error, :requires_reencryption, _integration} ->
        {:error, :requires_reencryption}
    end
  end

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
    if credentials_in_attrs?(attrs) do
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

  # Callers supply the virtual field names (`:api_key`), never the encrypted
  # ones; those only exist after `encrypt_credentials/1` runs inside the
  # changeset, by which point the attrs have already been consumed.
  defp credentials_in_attrs?(attrs) when is_map(attrs) do
    Enum.any?(VideoIntegrationSchema.credential_fields(), &Map.has_key?(attrs, &1))
  end
end
