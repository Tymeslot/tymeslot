defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationLockQueries do
  @moduledoc """
  The transaction locks that serialise changes to a user's calendar
  integrations: primary-calendar moves, and guarding against the account
  being deleted underneath them.
  """

  import Ecto.Query

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc """
  Whether the caller runs inside a transaction, so a write can leave what
  must wait for the commit (dropping a cache) to the caller that commits.
  """
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Repo.in_transaction?()

  @doc """
  Holds the user's row `FOR KEY SHARE` for the rest of the transaction, so the
  account cannot be deleted under it: an account deletion locks that row
  `FOR UPDATE` before its cascade reaches the user's calendars and meeting
  types, and waits here, or this waits for it. `false` when the user is gone.

  Must be called from inside a `Repo.transaction/1`.
  """
  @spec lock_owner(integer()) :: boolean()
  def lock_owner(user_id) do
    Repo.exists?(from(u in UserSchema, where: u.id == ^user_id, lock: "FOR KEY SHARE"))
  end

  @doc """
  Locks the user's profile row, then every calendar integration row of theirs,
  for the rest of the transaction. Every change that can move the user's
  primary calendar takes it first (create, toggle, pause, delete, reconnect),
  so those changes run one at a time per user and always lock in the same
  order. A user without a profile has no primary to move, so locking nothing
  there is harmless.

  Must be called from inside a `Repo.transaction/1`.
  """
  @spec lock_user_profile_and_integrations(integer()) :: :ok
  def lock_user_profile_and_integrations(user_id) do
    _locked_profile =
      Repo.one(from(p in ProfileSchema, where: p.user_id == ^user_id, lock: "FOR UPDATE"))

    _locked_integration_ids =
      Repo.all(
        from(ci in CalendarIntegrationSchema,
          where: ci.user_id == ^user_id,
          order_by: ci.id,
          select: ci.id,
          lock: "FOR UPDATE"
        )
      )

    :ok
  end
end
