defmodule Tymeslot.Integrations.Stripe.IdempotencyKey do
  @moduledoc """
  The only place Stripe idempotency keys are formatted.

  A key names an intent, not a call: the same refund, retried by any layer,
  sends the same key, so Stripe replays its stored result instead of acting
  twice. Pass an `attempt` when a stored failure must not be replayed.
  """

  @doc """
  `"tymeslot:<kind>:<id>"`, or `"tymeslot:<kind>:<id>:<attempt>"` for a
  positive integer `attempt`. `id` is rendered with `to_string/1`; an empty id
  raises `ArgumentError`.
  """
  @spec for_intent(atom(), term(), pos_integer() | nil) :: String.t()
  def for_intent(kind, id, attempt \\ nil) when is_atom(kind) do
    case to_string(id) do
      "" -> raise ArgumentError, "idempotency key needs a non-empty id"
      id -> key(kind, id, attempt)
    end
  end

  defp key(kind, id, nil), do: "tymeslot:#{kind}:#{id}"

  defp key(kind, id, attempt) when is_integer(attempt) and attempt > 0,
    do: "tymeslot:#{kind}:#{id}:#{attempt}"
end
