defmodule Tymeslot.MeetingTypes.EmailVerificationRule do
  @moduledoc """
  The email verification rule of a meeting type's changeset, kept apart from
  `Tymeslot.MeetingTypes.MeetingTypeSchema` like the payment rules
  (`Tymeslot.MeetingTypes.PaymentValidation`).

  A paid booking is confirmed by its payment, so a type cannot also ask the
  booker to verify their email address. Both fields are read with
  `get_field/2`, so turning either on for a type that already has the other is
  refused too. The error sits on `:requires_email_verification`. Group
  bookings and series exclude it too, with their other conflicts
  (`Tymeslot.MeetingTypes.GroupValidation`,
  `Tymeslot.MeetingTypes.SeriesSettings.conflicts/1`).

  The message is a msgid of the `errors` domain, registered with
  `dgettext_noop/2` and translated where the form shows it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset, only: [add_error: 3, get_field: 2]

  @doc """
  Refuses a meeting type that requires both email verification and payment.
  """
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(changeset) do
    if get_field(changeset, :requires_email_verification) == true and
         get_field(changeset, :payment_required) == true do
      add_error(
        changeset,
        :requires_email_verification,
        dgettext_noop("errors", "email confirmation cannot be combined with payment")
      )
    else
      changeset
    end
  end
end
