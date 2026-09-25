defmodule Tymeslot.Emails.Templates.AppointmentCancellationRefundNoticeTest do
  @moduledoc """
  The host-facing refund notice on the cancellation email.

  Lives apart from `AppointmentCancellationTest` because that module is already
  at the size limit, and because this is one self-contained behaviour: a
  cancellation settles nothing, so the host's copy has to say when they are
  still holding the attendee's money.
  """

  use Tymeslot.DataCase, async: true

  import Tymeslot.EmailTestHelpers

  @moduletag :emails
  @moduletag :payments

  alias Tymeslot.Emails.Templates.AppointmentCancellation

  # A cancellation settles nothing: the host may have cancelled without
  # refunding, or the attendee may have cancelled, in which case no refund is
  # offered at all and the money simply stays with the host. Nothing else tells
  # them, so the host's copy of this email carries the outstanding balance.
  describe "render/3 with :organizer, outstanding refund notice" do
    defp details_with_payment(payment) do
      build_appointment_details(%{booking_payment: payment})
    end

    defp paid_payment(overrides \\ %{}) do
      Map.merge(
        %{
          status: "paid",
          amount_cents: 5000,
          refunded_amount_cents: 0,
          currency: "eur",
          paid_at: ~U[2026-01-10 09:00:00Z]
        },
        overrides
      )
    end

    defp organizer_email(details) do
      AppointmentCancellation.render(:organizer, "organizer@example.com", details)
    end

    test "names the outstanding amount when nothing has been refunded" do
      email = organizer_email(details_with_payment(paid_payment()))

      assert email.html_body =~ "Refund outstanding"
      assert email.html_body =~ "€50.00"
      assert email.text_body =~ "REFUND OUTSTANDING:"
      assert email.text_body =~ "€50.00"
    end

    test "names only the balance left after a partial refund" do
      payment =
        paid_payment(%{status: "partially_refunded", refunded_amount_cents: 2000})

      email = organizer_email(details_with_payment(payment))

      assert email.html_body =~ "€30.00"
      assert email.text_body =~ "€30.00"
      refute email.html_body =~ "€50.00"
    end

    test "tells the host cancelling did not refund anything by itself" do
      email = organizer_email(details_with_payment(paid_payment()))

      assert email.html_body =~ "Cancelling does not refund anything on its own"
      assert email.text_body =~ "Cancelling does not refund anything on its own"
    end

    test "says nothing when the booking was refunded in full" do
      payment = paid_payment(%{status: "refunded", refunded_amount_cents: 5000})

      email = organizer_email(details_with_payment(payment))

      refute email.html_body =~ "Refund outstanding"
      refute email.text_body =~ "REFUND OUTSTANDING:"
    end

    test "says nothing when the charge is disputed, as Stripe owns that" do
      email = organizer_email(details_with_payment(paid_payment(%{status: "disputed"})))

      refute email.html_body =~ "Refund outstanding"
    end

    test "says nothing for a free booking, which carries no payment" do
      email = organizer_email(build_appointment_details(%{booking_payment: nil}))

      refute email.html_body =~ "Refund outstanding"
      refute email.text_body =~ "REFUND OUTSTANDING:"
    end

    # Telling a booker money is owed that the host may never send would be
    # worse than saying nothing, so the notice is host-only.
    test "is absent from the attendee's copy" do
      details = details_with_payment(paid_payment())

      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details)

      refute email.html_body =~ "Refund outstanding"
      refute email.text_body =~ "REFUND OUTSTANDING:"
    end
  end
end
