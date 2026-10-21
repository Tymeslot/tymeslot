defmodule Tymeslot.MeetingTypes.PaymentAccess do
  @moduledoc """
  Whether a host's paid meeting types can be sold right now.

  A paid type keeps its price when its host disconnects Stripe or their plan
  stops including payments, so it resumes as it was once they reconnect
  (`Tymeslot.Bookings.Create`). Until then it is *unsellable*: every booking
  already made on it stands, but no booking on it could succeed, because the
  submit refuses it (`:payments_unavailable`).

  An unsellable type is treated by the public booking page as a paused group
  type is (`Tymeslot.MeetingTypes.GroupAccess`): it is left off the host's
  listing and its direct link resolves to nothing, so a booker never fills in
  a form that cannot be submitted. The submit keeps its own check, for a page
  that was open before the host lost the ability to take payments.
  """

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @doc """
  `meeting_types` without the paid ones whose host is not accepting payments.
  Payments are checked once per host, and only when the list holds a paid
  type at all, so a host with none pays nothing for it.
  """
  @spec reject_unsellable([MeetingTypeSchema.t()]) :: [MeetingTypeSchema.t()]
  def reject_unsellable(meeting_types) do
    unsellable_hosts =
      meeting_types
      |> Enum.filter(&paid?/1)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> Enum.reject(&MeetingPayments.accepting_payments?/1)

    if unsellable_hosts == [] do
      meeting_types
    else
      Enum.reject(meeting_types, &(paid?(&1) and &1.user_id in unsellable_hosts))
    end
  end

  defp paid?(%MeetingTypeSchema{payment_required: true}), do: true
  defp paid?(_meeting_type), do: false
end
