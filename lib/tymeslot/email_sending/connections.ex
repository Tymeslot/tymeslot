defmodule Tymeslot.EmailSending.Connections do
  @moduledoc """
  Allows ten custom SMTP connections per owner on the running node.

  Booking deliveries and configuration tests share monitored connection slots,
  regardless of configuration revision. Ten slots accommodate the normal email
  queue's concurrency without repeatedly snoozing a healthy group fan-out.
  When every slot is full, workers use their existing bounded rate-limit snooze
  without changing breaker state. Holders release slots on return or death.

  This is a node-local cap. Restarting the shared lock manager forgets active
  reservations, and multiple nodes have independent caps. It does not claim a
  strict cluster-wide or restart-persistent concurrency guarantee.
  """

  alias Tymeslot.Integrations.Shared.Lock

  require Logger

  @limit 10

  @type refusal :: :rate_limited | :connection_unavailable | :invalid_owner

  @doc "The maximum simultaneous custom SMTP sends for one owner on this node."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Runs bounded SMTP work under the owner's nonblocking connection reservation.

  The caller remains the lock holder and runs `fun` in its own process, keeping
  the delivery pipeline's ambiguity callbacks and claims in their original scope.
  An unavailable lock manager fails closed; no send runs without a reservation.
  """
  @spec with_owner(pos_integer(), (-> result)) :: result | {:error, refusal()}
        when result: term()
  def with_owner(owner_id, fun)
      when is_integer(owner_id) and owner_id > 0 and is_function(fun, 0) do
    with_slot(owner_id, 1, fun)
  rescue
    _error ->
      Logger.warning("User SMTP connection reservation unavailable")
      {:error, :connection_unavailable}
  catch
    _kind, _reason ->
      Logger.warning("User SMTP connection reservation terminated")
      {:error, :connection_unavailable}
  end

  def with_owner(_owner_id, _fun), do: {:error, :invalid_owner}

  defp with_slot(owner_id, slot, fun) when slot <= @limit do
    # Tag callback outcomes so a returned error cannot look like a refused
    # acquisition and accidentally run the same SMTP work in another slot.
    case Lock.with_lock(
           {:user_smtp_connection, owner_id, slot},
           fn -> {:smtp_connection_result, fun.()} end,
           mode: :non_blocking
         ) do
      {:smtp_connection_result, result} -> result
      {:error, :refresh_in_progress} -> with_slot(owner_id, slot + 1, fun)
      {:error, :lock_manager_not_started} -> {:error, :connection_unavailable}
    end
  end

  defp with_slot(_owner_id, _slot, _fun), do: {:error, :rate_limited}
end
