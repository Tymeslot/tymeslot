defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GroupRules do
  @moduledoc """
  What stands between the meeting-type form's current state and turning
  group bookings on, and how the form explains it.

  The rules themselves belong to the domain: the meeting-type changeset
  refuses a group type that requires payment or approval or whose location
  is not fixed in advance (`Tymeslot.MeetingTypes.GroupLocationRule`), and
  `Tymeslot.MeetingTypes.FormValidation` refuses enabling group bookings
  without plan access. This module asks the same questions of the form's
  unsaved state, so the toggle can be disabled with a reason instead of
  failing on save, and both the toggle's event handler and the section's
  markup read one answer.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.GroupLocationRule

  @typedoc "Why group bookings cannot be turned on right now."
  @type blocker ::
          :plan | :payment | :approval | {:location, GroupLocationRule.reason()}

  @doc """
  The first reason group bookings cannot be turned on, or nil when nothing
  stands in the way. Turning them off is never blocked.
  """
  @spec enable_blocker(map()) :: blocker() | nil
  def enable_blocker(assigns) do
    cond do
      not Map.get(assigns, :group_bookings_allowed, true) ->
        :plan

      # Hosts who lost charge capability cannot reach the payments toggle, so
      # turning group bookings on clears `payment_required` for them instead.
      assigns.payment_required and assigns.payments_charges_enabled ->
        :payment

      assigns.requires_approval ->
        :approval

      true ->
        location_blocker(assigns.locations)
    end
  end

  defp location_blocker(locations) do
    case GroupLocationRule.check(locations) do
      :ok -> nil
      {:error, reason} -> {:location, reason}
    end
  end

  @doc """
  What the host has to change for these locations to suit a group type.
  """
  @spec location_message(GroupLocationRule.reason()) :: String.t()
  def location_message(:not_single_location) do
    dgettext(
      "dashboard_meeting_form",
      "Group bookings need exactly one location, so everyone in a slot meets in the same place. Remove the other locations to enable them."
    )
  end

  def location_message(:provider_choice) do
    dgettext(
      "dashboard_meeting_form",
      "Group bookings need a single video provider. Edit the location so it uses just one."
    )
  end

  def location_message(:venue_choice) do
    dgettext(
      "dashboard_meeting_form",
      "Group bookings need a single venue. Edit the location so it names just one."
    )
  end

  def location_message(:address_after_booking) do
    dgettext(
      "dashboard_meeting_form",
      "Group bookings need the address up front. Edit the location and choose a venue."
    )
  end

  def location_message(:booker_phone) do
    dgettext(
      "dashboard_meeting_form",
      "Group bookings cannot ask each booker for their phone number. Edit the location to publish a number for them to call instead."
    )
  end
end
