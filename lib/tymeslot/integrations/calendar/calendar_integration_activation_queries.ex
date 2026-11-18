defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationActivationQueries do
  @moduledoc """
  Pausing and reactivating calendar integrations, and the check that keeps a
  reactivated row clear of the `is_active`-predicated unique indexes.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  @doc """
  Sets the integration inactive, never the other way round: the write forces
  `is_active` to false whatever the struct says, so a stale struct cannot turn
  a pause into a no-op or a reactivation.
  """
  @spec deactivate(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Changeset.t()}
  def deactivate(%CalendarIntegrationSchema{} = integration) do
    integration
    |> Changeset.change()
    |> Changeset.force_change(:is_active, false)
    |> Repo.update()
  end

  @doc """
  Toggles the active status of an integration.

  When reactivating, checks that no other active integration exists for the same
  `(user_id, provider, provider_account_id)` to prevent a unique-constraint violation.
  """
  @spec toggle_active(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :duplicate_account}
  def toggle_active(%CalendarIntegrationSchema{} = integration) do
    if integration.is_active do
      integration
      |> CalendarIntegrationSchema.activation_changeset(false)
      |> Repo.update()
    else
      case check_reactivation_conflict(integration) do
        :ok ->
          integration
          |> CalendarIntegrationSchema.activation_changeset(true)
          |> Repo.update()

        {:error, :duplicate_account} = err ->
          err
      end
    end
  end

  # Every uniqueness index here is predicated on `is_active = true`, so
  # reactivating a row moves it *into* the index. A row whose account id is
  # NULL falls under the legacy-row index on `(user_id, provider)`, and one
  # whose account id is the empty string falls under the account index, because
  # `''` is not NULL. Waving both through returned `:ok` for exactly the rows
  # that contend, with no concurrency involved at all.
  @spec check_reactivation_conflict(CalendarIntegrationSchema.t()) ::
          :ok | {:error, :duplicate_account}
  def check_reactivation_conflict(%{provider_account_id: nil} = integration) do
    if active_null_account_exists?(integration.user_id, integration.provider) do
      {:error, :duplicate_account}
    else
      :ok
    end
  end

  def check_reactivation_conflict(integration) do
    if active_account_exists?(
         integration.user_id,
         integration.provider,
         integration.provider_account_id
       ) do
      {:error, :duplicate_account}
    else
      :ok
    end
  end

  # Existence-only checks: the reactivation conflict check never needs the
  # conflicting row's credentials, and decrypting them (as the equivalent
  # `get_*` lookups do) can raise on a row whose ciphertext no longer decrypts
  # under the current keyring — turning a refusal into a crash.
  defp active_null_account_exists?(user_id, provider) do
    CalendarIntegrationSchema
    |> where(
      [c],
      c.user_id == ^user_id and c.provider == ^provider and
        is_nil(c.provider_account_id) and c.is_active == true
    )
    |> Repo.exists?()
  end

  defp active_account_exists?(user_id, provider, provider_account_id) do
    CalendarIntegrationSchema
    |> where(
      [c],
      c.user_id == ^user_id and
        c.provider == ^provider and
        c.provider_account_id == ^provider_account_id and
        c.is_active == true
    )
    |> Repo.exists?()
  end
end
