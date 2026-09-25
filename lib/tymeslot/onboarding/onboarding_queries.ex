defmodule Tymeslot.Onboarding.OnboardingQueries do
  @moduledoc """
  Writes to the onboarding and dashboard setup columns of the `users` table.
  Idempotence and validation live in `Tymeslot.Onboarding`.
  """
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo

  @doc """
  Marks a user's onboarding as complete.
  """
  @spec mark_onboarding_complete(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def mark_onboarding_complete(%UserSchema{} = user) do
    user
    |> Changeset.change(%{
      onboarding_completed_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc """
  Sets `dashboard_tour_seen_at` to the current UTC time for `user`.

  This is an unconditional write — idempotence is enforced at the context level
  by `Onboarding.mark_dashboard_tour_seen/1`.
  """
  @spec mark_dashboard_tour_seen(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def mark_dashboard_tour_seen(%UserSchema{} = user) do
    user
    |> Changeset.change(%{
      dashboard_tour_seen_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
  end

  @doc """
  Adds `item` to the host's manually-ticked dashboard setup items, or removes it
  when it is already there, in a single statement. Membership is read from the
  stored row, so concurrent toggles from two tabs never clobber each other.

  Returns `user` carrying the stored list, with its preloads intact.
  """
  @spec toggle_dashboard_setup_done_item(UserSchema.t(), String.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def toggle_dashboard_setup_done_item(%UserSchema{id: id} = user, item) when is_binary(item) do
    now = DateTime.utc_now(:second)

    query =
      from(u in UserSchema,
        where: u.id == ^id,
        update: [
          set: [
            dashboard_setup_done_items:
              fragment(
                "CASE WHEN ?::varchar = ANY(?) THEN array_remove(?, ?::varchar) ELSE array_append(?, ?::varchar) END",
                ^item,
                u.dashboard_setup_done_items,
                u.dashboard_setup_done_items,
                ^item,
                u.dashboard_setup_done_items,
                ^item
              ),
            updated_at: ^now
          ]
        ],
        select: u.dashboard_setup_done_items
      )

    case Repo.update_all(query, []) do
      {1, [items]} ->
        {:ok, %{user | dashboard_setup_done_items: items, updated_at: now}}

      {0, _none} ->
        {:error, :not_found}
    end
  end

  @doc """
  Stamps `dashboard_setup_dismissed_at` so the onboarding widget stays closed.
  """
  @spec mark_dashboard_setup_dismissed(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Changeset.t()}
  def mark_dashboard_setup_dismissed(%UserSchema{} = user) do
    user
    |> Changeset.change(%{dashboard_setup_dismissed_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end
end
