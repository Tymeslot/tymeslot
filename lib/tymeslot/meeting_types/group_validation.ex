defmodule Tymeslot.MeetingTypes.GroupValidation do
  @moduledoc """
  The group rules of a meeting type's changeset, kept apart from
  `Tymeslot.MeetingTypes.MeetingTypeSchema` like the reminder and payment
  rules (`Tymeslot.MeetingTypes.ReminderValidation`,
  `Tymeslot.MeetingTypes.PaymentValidation`).

  What a group type (more than one participant per slot) cannot also be.
  Everyone in a group slot shares one meeting row, so nothing about that row
  may be decided per booker:

    * payment: per-seat payment is out of scope;
    * approval: the approval flow answers one booker's request for a whole
      meeting, and a shared slot has no single booker to answer;
    * the location: see `Tymeslot.MeetingTypes.GroupLocationRule`;
    * further lengths: see `Tymeslot.MeetingTypes.Lengths.validate_changeset/1`;
    * invitation-only: an invitation link books one person into one slot.

  Read with `get_field/2` so a change to either side (the limit, or the other
  setting) is caught.

  The messages are msgids of the `errors` domain, registered here with
  `dgettext_noop/2` and translated where the form shows them, like Ecto's own
  validator messages (`TymeslotWeb.Gettext.EctoErrorMsgids`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset, only: [add_error: 3, get_field: 2]

  alias Tymeslot.MeetingTypes.GroupLocationRule

  @doc "Validates a meeting type changeset against every group rule."
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(changeset) do
    changeset
    |> validate_group_rules()
    |> validate_invitation_only_not_group()
  end

  @doc """
  A group type cannot be invitation-only, nor the reverse. Reads `get_field/2`
  so a form that does not send the flag still has it checked; an explicit nil
  counts as not invitation-only.
  """
  @spec validate_invitation_only_not_group(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_invitation_only_not_group(changeset) do
    invitation_only? = get_field(changeset, :invitation_only) == true

    if invitation_only? and group_limit?(get_field(changeset, :max_participants)) do
      add_error(
        changeset,
        :invitation_only,
        dgettext_noop("errors", "Invitation links work only for one-to-one meeting types.")
      )
    else
      changeset
    end
  end

  @doc """
  The error message for a group type's in-person location left without a
  venue, for the changeset that takes a venue off a meeting type.
  """
  @spec venue_required_message() :: String.t()
  def venue_required_message, do: group_location_message(:address_after_booking)

  defp validate_group_rules(changeset) do
    if group_limit?(get_field(changeset, :max_participants)) do
      changeset
      |> refuse_for_group(
        :payment_required,
        dgettext_noop("errors", "group bookings cannot require payment")
      )
      |> refuse_for_group(
        :requires_approval,
        dgettext_noop("errors", "group bookings cannot require approval")
      )
      |> validate_group_location()
    else
      changeset
    end
  end

  defp group_limit?(max), do: is_integer(max) and max > 1

  defp refuse_for_group(changeset, field, message) do
    if get_field(changeset, field) == true,
      do: add_error(changeset, :max_participants, message),
      else: changeset
  end

  # The effective options, including the single fallback option a type with
  # no stored list offers, so a group type cannot slip through on the
  # "address arranged after booking" fallback.
  defp validate_group_location(changeset) do
    offered = %{
      locations: get_field(changeset, :locations),
      allow_video: get_field(changeset, :allow_video),
      video_integration_id: get_field(changeset, :video_integration_id)
    }

    case GroupLocationRule.check_meeting_type(offered) do
      :ok -> changeset
      {:error, reason} -> add_error(changeset, :locations, group_location_message(reason))
    end
  end

  defp group_location_message(:not_single_location),
    do: dgettext_noop("errors", "a group meeting type must offer exactly one location")

  defp group_location_message(:provider_choice),
    do: dgettext_noop("errors", "a group meeting type's video call must use exactly one provider")

  defp group_location_message(:venue_choice),
    do:
      dgettext_noop(
        "errors",
        "a group meeting type's in-person location must name exactly one venue"
      )

  defp group_location_message(:address_after_booking),
    do: dgettext_noop("errors", "a group meeting type's in-person location must name a venue")

  defp group_location_message(:booker_phone),
    do:
      dgettext_noop(
        "errors",
        "a group meeting type cannot ask each booker for their phone number"
      )
end
