defmodule Tymeslot.MeetingPayments.RefundQueries do
  @moduledoc """
  All Repo.* calls for booking_payment_refunds.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Repo

  # Far longer than any one attempt can take (the client's largest deadline
  # is 20 s, which it may overrun by one connect timeout), so a stalled
  # process is not mistaken for a dead one.
  @lease_seconds 300

  # The database's clock as a UTC timestamp, the type the lease column has.
  # The statement's own time, not the transaction's, which may be old.
  defmacrop db_now do
    quote do: fragment("(statement_timestamp() AT TIME ZONE 'UTC')")
  end

  @doc "Whether the calling process is inside a transaction."
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Repo.in_transaction?()

  @spec insert!(Changeset.t()) :: RefundSchema.t()
  def insert!(%Changeset{} = changeset), do: Repo.insert!(changeset)

  @spec get(term()) :: RefundSchema.t() | nil
  def get(id) do
    case UUID.cast(id) do
      {:ok, uuid} -> Repo.get(RefundSchema, uuid)
      :error -> nil
    end
  end

  @doc """
  Fetches a refund and holds its row lock for the rest of the current
  transaction, or `nil`. Must be called inside a `Repo.transaction/1`.
  """
  @spec get_for_update(UUID.t()) :: RefundSchema.t() | nil
  def get_for_update(id),
    do: Repo.one(from(r in RefundSchema, where: r.id == ^id, lock: "FOR UPDATE"))

  @doc "What the pending refunds of a payment add up to, in cents."
  @spec pending_cents(UUID.t()) :: non_neg_integer()
  def pending_cents(booking_payment_id) do
    Repo.one(
      from(r in RefundSchema,
        where: r.booking_payment_id == ^booking_payment_id and r.status == :pending,
        select: type(coalesce(sum(r.amount_cents), 0), :integer)
      )
    )
  end

  @doc "A payment's refunds, oldest first."
  @spec list_for_payment(UUID.t()) :: [RefundSchema.t()]
  def list_for_payment(booking_payment_id) do
    Repo.all(
      from(r in RefundSchema,
        where: r.booking_payment_id == ^booking_payment_id,
        order_by: [asc: r.inserted_at, asc: r.id]
      )
    )
  end

  @doc "The ids of the refunds still pending that were recorded before `cutoff`."
  @spec pending_ids_recorded_before(DateTime.t()) :: [UUID.t()]
  def pending_ids_recorded_before(%DateTime{} = cutoff) do
    Repo.all(
      from(r in RefundSchema,
        where: r.status == :pending and r.inserted_at < ^cutoff,
        select: r.id
      )
    )
  end

  @spec by_stripe_refund_id(String.t()) :: RefundSchema.t() | nil
  def by_stripe_refund_id(stripe_refund_id) when is_binary(stripe_refund_id),
    do: Repo.get_by(RefundSchema, stripe_refund_id: stripe_refund_id)

  @doc """
  Starts one attempt at a pending refund: counts it and takes the lease for
  #{@lease_seconds} seconds, in one statement committed on its own, so the
  attempt's number is spent even if the process dies during it. The lease
  is read and written by the database's clock, so app servers whose clocks
  disagree still agree on it.

  Returns the refund as claimed, `:busy` while another attempt holds an
  unexpired lease, or `:not_pending` for a refund settled (or gone).
  """
  @spec claim_attempt(RefundSchema.t()) :: {:ok, RefundSchema.t()} | :not_pending | :busy
  def claim_attempt(%RefundSchema{id: id}) do
    query =
      from(r in RefundSchema,
        where: r.id == ^id and r.status == :pending,
        where: is_nil(r.executing_until) or r.executing_until < db_now(),
        select: r,
        update: [
          inc: [attempt: 1],
          set: [
            executing_until: fragment("? + make_interval(secs => ?)", db_now(), ^@lease_seconds),
            updated_at: db_now()
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, [claimed]} ->
        {:ok, claimed}

      {0, []} ->
        case Repo.get(RefundSchema, id) do
          %RefundSchema{status: :pending} -> :busy
          _settled_or_gone -> :not_pending
        end
    end
  end

  @doc """
  Gives up the lease the `claimed` attempt took. A later attempt that has
  claimed the refund since keeps its own.
  """
  @spec release(RefundSchema.t()) :: :ok
  def release(%RefundSchema{} = claimed) do
    Repo.update_all(claimed_by(claimed), set: [executing_until: nil])
    :ok
  end

  @doc """
  Settles a refund Stripe made with `attrs` (`RefundSchema.settle_changeset/2`)
  and clears its lease, whichever attempt holds it: money Stripe moved
  stands however it was learnt of, so a refund settled `failed` is settled
  again, its failure code cleared. A refund already `succeeded` is left
  alone and returns `{:error, :not_pending}`, and a Stripe refund another
  row holds `{:error, :stripe_refund_taken}`.
  """
  @spec settle(RefundSchema.t(), map()) ::
          {:ok, RefundSchema.t()} | {:error, :not_pending | :stripe_refund_taken | Changeset.t()}
  def settle(%RefundSchema{id: id} = refund, attrs) do
    made = from(r in RefundSchema, where: r.id == ^id and r.status in [:pending, :failed])
    settle_where(made, refund, attrs, failure_code: nil)
  end

  @doc """
  As `settle/2`, but only while the `claimed` attempt is the latest: an
  attempt whose lease ran out and was claimed again since no longer decides
  the refund, and gets `{:error, :not_pending}`.
  """
  @spec settle_claimed(RefundSchema.t(), map()) ::
          {:ok, RefundSchema.t()} | {:error, :not_pending | Changeset.t()}
  def settle_claimed(%RefundSchema{} = claimed, attrs) do
    claimed
    |> claimed_by()
    |> where([r], r.status == :pending)
    |> settle_where(claimed, attrs, [])
  end

  defp settle_where(query, refund, attrs, also_set) do
    case RefundSchema.settle_changeset(refund, attrs) do
      %Changeset{valid?: true, changes: changes} ->
        set =
          also_set
          |> Keyword.merge(Map.to_list(changes))
          |> Keyword.merge(executing_until: nil, updated_at: changes.settled_at)

        update_settled(from(r in query, select: r), set)

      invalid ->
        {:error, invalid}
    end
  end

  # A Stripe refund already on another row (two rows adopting one refund)
  # is refused rather than raised, so the attempt is retried and finds it
  # recorded.
  defp update_settled(query, set) do
    case Repo.update_all(query, set: set) do
      {1, [settled]} -> {:ok, settled}
      {0, []} -> {:error, :not_pending}
    end
  rescue
    error in Postgrex.Error ->
      if match?(%{postgres: %{code: :unique_violation}}, error),
        do: {:error, :stripe_refund_taken},
        else: reraise(error, __STACKTRACE__)
  end

  defp claimed_by(%RefundSchema{id: id, attempt: attempt}),
    do: from(r in RefundSchema, where: r.id == ^id and r.attempt == ^attempt)
end
