defmodule TymeslotWeb.Live.Scheduling.InvitationMessages do
  @moduledoc """
  What a booker is told when an invitation link does not open the booking:
  the `Tymeslot.Invitations.resolve/1` refusals, and `:required` for an
  invitation-only type reached without a valid link. Shared by the `/invite`
  link (`TymeslotWeb.BookingInvitationController`) and the booking page's
  entry gate, so a link refused at either says the same thing.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage

  @type reason :: :used | :expired | :revoked | :required

  @doc "The booker's copy for why an invitation link did not open the booking."
  @spec message(reason()) :: String.t()
  def message(:used) do
    dgettext(
      "booking_errors",
      "This invitation link has already been used to book an appointment. To change it, use the link in your confirmation email."
    )
  end

  def message(:expired) do
    dgettext(
      "booking_errors",
      "This invitation link has expired. Please contact the host for a new one."
    )
  end

  def message(:revoked) do
    dgettext(
      "booking_errors",
      "This invitation link is no longer valid. Please contact the host for a new one."
    )
  end

  # The same refusal the submit makes for a booking with no invitation.
  def message(:required), do: BookingErrorMessage.message(:invitation_required)
end
