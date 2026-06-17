defmodule Tymeslot.MeetingPayments.ConnectAccountQueries do
  @moduledoc """
  All Repo.* calls for connect_accounts.
  """

  import Ecto.Query
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.Repo

  @spec get(Ecto.UUID.t()) :: ConnectAccountSchema.t() | nil
  def get(id), do: Repo.get(ConnectAccountSchema, id)

  @spec live_for_user(integer()) :: ConnectAccountSchema.t() | nil
  def live_for_user(user_id) do
    Repo.one(
      from c in ConnectAccountSchema,
        where: c.user_id == ^user_id and is_nil(c.deleted_at),
        limit: 1
    )
  end

  @spec by_stripe_account_id(String.t()) :: ConnectAccountSchema.t() | nil
  def by_stripe_account_id(stripe_account_id) do
    Repo.one(
      from c in ConnectAccountSchema,
        where: c.stripe_account_id == ^stripe_account_id and is_nil(c.deleted_at),
        limit: 1
    )
  end

  @spec insert_placeholder(integer(), String.t()) ::
          {:ok, ConnectAccountSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_placeholder(user_id, country) do
    %ConnectAccountSchema{}
    |> ConnectAccountSchema.changeset(%{
      user_id: user_id,
      country: country,
      status: "creating"
    })
    |> Repo.insert()
  end

  @spec update(ConnectAccountSchema.t(), map()) ::
          {:ok, ConnectAccountSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(schema, attrs) do
    schema
    |> ConnectAccountSchema.changeset(attrs)
    |> Repo.update()
  end

  @spec soft_delete_for_user(integer(), DateTime.t()) :: {non_neg_integer(), nil}
  def soft_delete_for_user(user_id, now) do
    query =
      from(c in ConnectAccountSchema,
        where: c.user_id == ^user_id and is_nil(c.deleted_at)
      )

    Repo.update_all(query,
      set: [
        deleted_at: now,
        charges_enabled: false,
        status: "deleted",
        user_id: nil,
        updated_at: now
      ]
    )
  end
end
