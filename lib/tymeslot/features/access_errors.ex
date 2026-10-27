defmodule Tymeslot.Features.AccessErrors do
  @moduledoc """
  The refusals `Tymeslot.Features.check_access/2` returns, and a guard that
  matches them.

  Kept apart from `Tymeslot.Features`, and depending on nothing, so callers
  can import the guard at compile time without recompiling whenever the
  access check's own dependencies change.
  """

  @access_errors [
    :insufficient_plan,
    :feature_disabled,
    :pro_required,
    :stripe_required,
    :feature_access_checker_failed
  ]

  @type t :: unquote(@access_errors |> Enum.reverse() |> Enum.reduce(&{:|, [], [&1, &2]}))

  @doc """
  Whether `reason` is one of the refusals `check_access/2` returns, for use
  in a guard where a caller matches an `{:error, reason}` from a gated
  action.
  """
  defguard is_access_error(reason) when reason in @access_errors
end
