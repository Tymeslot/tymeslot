defmodule Tymeslot.InviteeData.SeatHoldErasureQueries do
  @moduledoc """
  The seat holds (`seat_holds`) an erasure finds by email and clears, for
  `Tymeslot.InviteeData`, beside `Tymeslot.InviteeData.InviteeDataQueries`,
  whose `scope` and placeholder address they share. A hold names a person
  as its booker or as one of its guests.

  Pure data access.
  """

  import Ecto.Query

  alias Tymeslot.InviteeData.InviteeDataQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.SeatHoldSchema, as: SeatHold
  alias Tymeslot.Repo

  @doc """
  A filter on a query binding the hold `as: :hold`: the hold names `email`,
  already lower-cased, as its booker or as one of its guests.
  """
  @spec hold_names_email(String.t()) :: Ecto.Query.dynamic_expr()
  def hold_names_email(email) do
    dynamic(
      [hold: h],
      fragment("lower(?)", h.email) == ^email or
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS g WHERE lower(g->>'email') = ?)",
          h.guests,
          ^email
        )
    )
  end

  @doc """
  Deletes the settled (converted or released) seat holds that name `email`,
  as the booker or as one of their guests. A hold still `held` is either an
  open checkout, which `InviteeDataQueries.upcoming_meeting_uids/4` refuses
  the erasure over, or one left to settle (`scrub_held_for_email/3`). A
  converted hold's booker lives on as a participant, scrubbed with the
  other seats; its payment is kept, its `seat_hold_id` nilified. Keeps to
  `scope`'s meetings.
  """
  @spec delete_settled_for_email(String.t(), InviteeDataQueries.scope()) ::
          {non_neg_integer(), nil}
  def delete_settled_for_email(email, scope) do
    from(h in SeatHold,
      as: :hold,
      where: h.status != :held,
      where: ^hold_names_email(email)
    )
    |> scope_holds(scope)
    |> Repo.delete_all()
  end

  @doc """
  Clears what `email` gave on the seat holds still `held` that name it, as
  the booker or as a guest, keeping each hold: they are past their window
  (or their meeting is over), as `InviteeDataQueries.upcoming_meeting_uids/4`
  refused the erasure otherwise, but their seats and payment are still to
  be settled (`Tymeslot.Meetings.Workers.ExpireSeatHolds`), and a payment
  that completes after all converts or refunds a hold as it stands. A
  booker is cleared as a seat is (`InviteeDataQueries.scrub_participants/2`);
  a guest's address takes a placeholder of the hold's id and the guest's
  place in the list. Returns how many holds were cleared. Keeps to
  `scope`'s meetings.
  """
  @spec scrub_held_for_email(String.t(), InviteeDataQueries.scope(), DateTime.t()) ::
          {non_neg_integer(), nil}
  def scrub_held_for_email(email, scope, %DateTime{} = now) do
    {booked, nil} =
      from(h in SeatHold,
        where: h.status == :held and fragment("lower(?)", h.email) == ^email,
        update: [
          set: [
            name: "",
            email:
              fragment("'erased-' || ?::text || ?", h.id, ^InviteeDataQueries.erased_suffix()),
            phone: nil,
            company: nil,
            message: nil,
            custom_field_answers: ^%{},
            updated_at: ^now
          ]
        ]
      )
      |> scope_holds(scope)
      |> Repo.update_all([])

    {guested, nil} =
      from(h in SeatHold,
        as: :hold,
        where: h.status == :held,
        where: ^hold_names_email(email),
        update: [
          set: [
            guests:
              fragment(
                """
                (SELECT coalesce(jsonb_agg(CASE WHEN lower(g->>'email') = ?
                   THEN jsonb_build_object('name', NULL, 'email',
                     'erased-' || ?::text || '-' || n || ?)
                   ELSE g END ORDER BY n), '[]'::jsonb)
                 FROM jsonb_array_elements(?) WITH ORDINALITY AS t(g, n))
                """,
                ^email,
                h.id,
                ^InviteeDataQueries.erased_suffix(),
                h.guests
              ),
            updated_at: ^now
          ]
        ]
      )
      |> scope_holds(scope)
      |> Repo.update_all([])

    {booked + guested, nil}
  end

  defp scope_holds(query, :all), do: query

  defp scope_holds(query, host_user_id) when is_integer(host_user_id) do
    host_meetings = from(m in Meeting, where: m.organizer_user_id == ^host_user_id, select: m.id)
    where(query, [h], h.meeting_id in subquery(host_meetings))
  end
end
