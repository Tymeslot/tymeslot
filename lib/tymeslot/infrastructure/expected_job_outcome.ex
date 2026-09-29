defmodule Tymeslot.Infrastructure.ExpectedJobOutcome do
  @moduledoc """
  Lets an Oban worker say which of its own discards and cancels are an
  expected end rather than a failure.

  `Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes` records in
  ErrorTracker every job a worker ends with `{:discard, reason}` or
  `{:cancel, reason}`, except where the worker implements this behaviour and
  `expected_outcome?/1` returns `true` for the reason. Expected means the
  work no longer applies (its meeting or integration is gone), only the user
  can fix it (credentials to reconnect, their own endpoint refusing
  deliveries), or the failure already raises its own admin alert.

  The callback lives in the worker, beside the code that returns the reason,
  and should match the same terms the worker returns: a module attribute or a
  function shared by the return site and the callback, so the two cannot
  drift apart. A worker without the callback, or whose callback raises, has
  every discard and cancel recorded.
  """

  @doc """
  Returns `true` when `reason`, the second element of a `{:discard, reason}`
  or `{:cancel, reason}` this worker returned, is an expected end of the job.
  `nil` stands for a bare `:discard`.
  """
  @callback expected_outcome?(reason :: term()) :: boolean()
end
