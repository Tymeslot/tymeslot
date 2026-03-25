defmodule Tymeslot.Integrations.Common.OAuth.AccountMatch do
  @moduledoc """
  Shared helpers for matching OAuth accounts to existing integrations
  and handling race conditions during creation.
  """

  require Logger

  @doc """
  Verifies that the account from a new OAuth callback matches the existing integration.
  Allows the update when either side has a nil account ID (migration path).
  """
  @spec verify_account_match(map(), String.t() | nil, (-> result)) :: result
        when result: {:ok, any()} | {:error, any()}
  def verify_account_match(existing, new_account_id, update_fn) do
    cond do
      is_nil(existing.provider_account_id) and is_nil(new_account_id) ->
        update_fn.()

      is_nil(existing.provider_account_id) ->
        update_fn.()

      is_nil(new_account_id) ->
        Logger.warning(
          "OAuth re-authorization could not verify account identity — id_token decode may have failed",
          integration_id: existing.id,
          existing_account_id: existing.provider_account_id
        )

        {:error,
         "Could not verify your account identity. Please try again. If the problem persists, remove and re-add the integration."}

      existing.provider_account_id == new_account_id ->
        update_fn.()

      true ->
        Logger.warning("OAuth account mismatch during re-authorization",
          existing_account_id: existing.provider_account_id,
          new_account_id: new_account_id,
          integration_id: existing.id
        )

        {:error,
         "You authenticated with a different account than the one linked to this integration. Please use the correct account."}
    end
  end

  @doc """
  Creates a record with race condition protection against unique account constraint violations.

  If create fails with a unique account violation, retries by looking up the existing
  record and updating it instead.
  """
  @spec create_with_race_protection(
          create_fn :: (-> {:ok, any()} | {:error, Ecto.Changeset.t()}),
          lookup_fn :: (-> {:ok, any()} | {:error, :not_found}),
          update_fn :: (any() -> {:ok, any()} | {:error, any()})
        ) :: {:ok, any()} | {:error, any()}
  def create_with_race_protection(create_fn, lookup_fn, update_fn) do
    case create_fn.() do
      {:ok, _record} = success ->
        success

      {:error, %Ecto.Changeset{} = cs} ->
        if unique_account_violation?(cs) do
          case lookup_fn.() do
            {:ok, existing} -> update_fn.(existing)
            {:error, :not_found} -> {:error, cs}
          end
        else
          {:error, cs}
        end
    end
  end

  @doc """
  Finds an existing integration (active or inactive) by account, reactivating if needed,
  or creates a new one. Prevents duplicate rows when reconnecting an inactive account.

  - `find_any_fn` looks up any row (active or inactive) for the account
  - `update_fn` updates the found row's tokens and reactivates it
  - `create_fn` creates a new row if no match at all
  """
  @spec find_or_create_with_reactivation(
          find_any_fn :: (-> {:ok, any()} | {:error, :not_found}),
          update_fn :: (any() -> {:ok, any()} | {:error, any()}),
          create_fn :: (-> {:ok, any()} | {:error, any()})
        ) :: {:ok, any()} | {:error, any()}
  def find_or_create_with_reactivation(find_any_fn, update_fn, create_fn) do
    case find_any_fn.() do
      {:ok, existing} -> update_fn.(existing)
      {:error, :not_found} -> create_fn.()
    end
  end

  @doc """
  Checks if an Ecto changeset error is a unique account constraint violation.
  """
  @spec unique_account_violation?(Ecto.Changeset.t()) :: boolean()
  def unique_account_violation?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, [constraint: :unique, constraint_name: name]}} ->
        name in [
          "unique_active_video_account_per_user",
          "unique_active_calendar_account_per_user"
        ]

      _other ->
        false
    end)
  end
end
