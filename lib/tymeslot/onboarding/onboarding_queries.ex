defmodule Tymeslot.Onboarding.OnboardingQueries do
  @moduledoc """
  Writes to the onboarding and dashboard setup columns of the `users` table,
  and the candidate scan over recent accounts. Idempotence and validation
  live in `Tymeslot.Onboarding`.
  """
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc """
  Marks a user's onboarding as complete, keeping the original completion time
  when it is already set. The write is conditional on the column being null,
  so concurrent calls cannot both stamp it; the loser reads the winner's row.
  """
  @spec mark_onboarding_complete(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_found}
  def mark_onboarding_complete(%UserSchema{id: user_id}) do
    now = DateTime.utc_now(:second)

    query =
      from(u in UserSchema,
        where: u.id == ^user_id and is_nil(u.onboarding_completed_at),
        select: u
      )

    case Repo.update_all(query, set: [onboarding_completed_at: now, updated_at: now]) do
      {1, [updated]} -> {:ok, updated}
      {0, []} -> fetch_user(user_id)
    end
  end

  defp fetch_user(user_id) do
    case Repo.get(UserSchema, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
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

  @doc """
  One candidate row per account whose signup or verification falls after
  `window_start`, leaving out accounts pending deletion. `compose` receives
  the row query (`users` as the first binding, a map select) and may extend
  it before it runs.
  """
  @spec list_candidates_since(DateTime.t(), (Ecto.Query.t() -> Ecto.Query.t())) :: [map()]
  def list_candidates_since(%DateTime{} = window_start, compose) when is_function(compose, 1) do
    from([u] in candidate_rows(),
      where:
        (u.inserted_at > ^window_start or u.verified_at > ^window_start) and
          is_nil(u.deletion_scheduled_at)
    )
    |> compose.()
    |> Repo.all()
  end

  @doc "The candidate row for one account whatever its age, or `nil`."
  @spec get_candidate(integer(), (Ecto.Query.t() -> Ecto.Query.t())) :: map() | nil
  def get_candidate(user_id, compose) when is_integer(user_id) and is_function(compose, 1) do
    from([u] in candidate_rows(), where: u.id == ^user_id)
    |> compose.()
    |> Repo.one()
  end

  defp candidate_rows do
    from(u in UserSchema,
      left_join: p in ProfileSchema,
      on: p.user_id == u.id,
      select: %{
        user_id: u.id,
        signup_at: u.inserted_at,
        verified_at: u.verified_at,
        timezone: p.timezone,
        page_published?: not is_nil(p.booking_page_published_at)
      }
    )
  end
end
