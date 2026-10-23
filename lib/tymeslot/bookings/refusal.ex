defmodule Tymeslot.Bookings.Refusal do
  @moduledoc """
  A refusal decided by the booking rules rather than a failure: the meeting
  can no longer be cancelled or moved, its booker may not move it, or the
  requested time is outside what the host's schedule accepts.

  Its own module, with nothing to call at runtime, because callers use
  `is_refusal/1` in guards: a guard is expanded at compile time, so whatever
  the defining module calls would be compiled into each caller's dependencies.
  """

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.Validation

  @type t ::
          Policy.cancel_refusal()
          | Policy.reschedule_refusal()
          | Policy.booker_move_refusal()
          | Validation.booking_time_refusal()
          | :invalid_datetime

  @refusal_atoms [:already_cancelled, :in_past, :invalid_datetime, :managed_by_host]
  @refusal_tags [:not_cancellable, :not_reschedulable, :too_soon, :too_far_ahead]

  @doc "Whether `reason` is a `t/0`."
  defguard is_refusal(reason)
           when reason in @refusal_atoms or
                  (is_tuple(reason) and tuple_size(reason) == 2 and
                     elem(reason, 0) in @refusal_tags)
end
