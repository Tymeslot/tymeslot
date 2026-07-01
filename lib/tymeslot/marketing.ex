defmodule Tymeslot.Marketing do
  @moduledoc """
  The Marketing context.

  Owns a host's marketing-email opt-out state and the query for who is
  currently eligible to receive marketing email. The opt-out timestamp lives
  on the user record; this context is the single entry point for reading and
  changing it, so callers never touch that field directly.
  """

  alias Tymeslot.Auth.UserQueries

  @doc """
  Checks if a user has unsubscribed from marketing emails.
  """
  @spec unsubscribed?(Ecto.Schema.t()) :: boolean()
  def unsubscribed?(%{marketing_unsubscribed_at: nil}), do: false
  def unsubscribed?(_user), do: true

  @doc """
  Marks a user as unsubscribed from marketing emails. Idempotent.
  """
  @spec unsubscribe(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def unsubscribe(user) do
    if unsubscribed?(user) do
      {:ok, user}
    else
      UserQueries.set_marketing_unsubscribed_at(user, DateTime.utc_now(:second))
    end
  end

  @doc """
  Resubscribes a user to marketing emails. Idempotent.
  """
  @spec resubscribe(Ecto.Schema.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def resubscribe(user) do
    if unsubscribed?(user) do
      UserQueries.set_marketing_unsubscribed_at(user, nil)
    else
      {:ok, user}
    end
  end

  @doc """
  Returns the IDs of users currently eligible to receive marketing email — i.e.
  who have a verified email and have not unsubscribed from marketing.
  """
  @spec list_eligible_user_ids() :: [integer()]
  def list_eligible_user_ids do
    UserQueries.list_marketing_eligible_user_ids()
  end

  @doc """
  Returns the count of users currently eligible to receive marketing email.
  Prefer this over `list_eligible_user_ids/0` when you only need the number —
  it runs a single COUNT(*) without loading IDs into memory.
  """
  @spec count_eligible_user_ids() :: non_neg_integer()
  def count_eligible_user_ids do
    UserQueries.count_marketing_eligible_user_ids()
  end
end
