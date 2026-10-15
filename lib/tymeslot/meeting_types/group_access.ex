defmodule Tymeslot.MeetingTypes.GroupAccess do
  @moduledoc """
  Whether a host's group meeting types (`max_participants > 1`) may take new
  seats right now.

  Group bookings can be a gated feature (`:group_bookings_allowed`, answered
  by the configured `Tymeslot.Features` checker). Saving a meeting type is
  gated by `Tymeslot.MeetingTypes.FormValidation`, but a host who loses access
  afterwards still holds group types saved while they had it. Those types are
  *paused*: every booking already made on them stands, and each seat keeps
  its own cancel and move links, but nobody new takes a seat, neither the
  first one on a slot nor a join, until the host regains access or sets the
  type's limit back to one.

  A paused type is treated by the public booking page as an inactive one is:
  it is left off the host's listing and its direct link resolves to nothing,
  so a booker is never offered seats the booking submit would refuse. The
  submit refuses it as well (`Tymeslot.Bookings.CreateGroup.ensure_taking_seats/1`),
  for a page that was open before the host lost access.

  The default checker grants every feature, so a self-hosted install never
  pauses anything. A checker failure counts as no access, as the dashboard
  treats one.
  """

  alias Tymeslot.Features
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @doc "True when `meeting_type` is a group type its host may not take new seats on."
  @spec paused?(MeetingTypeSchema.t() | nil) :: boolean()
  def paused?(%MeetingTypeSchema{user_id: user_id} = meeting_type) do
    MeetingTypeSchema.group?(meeting_type) and not allowed?(user_id)
  end

  def paused?(_not_a_meeting_type), do: false

  @doc """
  `meeting_types` without the paused ones. The feature is checked once per
  host, and only when the list holds a group type at all, so a host with
  none pays nothing for it.
  """
  @spec reject_paused([MeetingTypeSchema.t()]) :: [MeetingTypeSchema.t()]
  def reject_paused(meeting_types) do
    paused_hosts =
      meeting_types
      |> Enum.filter(&MeetingTypeSchema.group?/1)
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> Enum.reject(&allowed?/1)

    if paused_hosts == [] do
      meeting_types
    else
      Enum.reject(meeting_types, &(MeetingTypeSchema.group?(&1) and &1.user_id in paused_hosts))
    end
  end

  defp allowed?(user_id), do: Features.check_access(user_id, :group_bookings_allowed) == :ok
end
