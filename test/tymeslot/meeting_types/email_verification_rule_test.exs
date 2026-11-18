defmodule Tymeslot.MeetingTypes.EmailVerificationRuleTest do
  @moduledoc """
  Email verification and payment exclude each other: a paid booking is
  confirmed by its payment, not by a verification link.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types
  @moduletag :schema

  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @message "email confirmation cannot be combined with payment"
  @payment_opts [host_charges_enabled: true, price_settable: true, currency: "eur"]

  defp changeset(struct, attrs) do
    MeetingTypeSchema.changeset(
      struct,
      Map.merge(%{name: "Call", duration_minutes: 30, user_id: 1}, attrs),
      @payment_opts
    )
  end

  test "email verification and payment are mutually exclusive" do
    cs =
      changeset(%MeetingTypeSchema{}, %{
        requires_email_verification: true,
        payment_required: true,
        price_cents: 5000
      })

    refute cs.valid?
    assert @message in errors_on(cs).requires_email_verification
  end

  test "email verification alone is valid" do
    assert changeset(%MeetingTypeSchema{}, %{requires_email_verification: true}).valid?
  end

  test "payment alone is valid" do
    assert changeset(%MeetingTypeSchema{}, %{payment_required: true, price_cents: 5000}).valid?
  end

  test "turning payment on for a verified type is refused" do
    stored = %MeetingTypeSchema{
      name: "Call",
      duration_minutes: 30,
      user_id: 1,
      requires_email_verification: true
    }

    cs = changeset(stored, %{payment_required: true, price_cents: 5000})

    refute cs.valid?
    assert @message in errors_on(cs).requires_email_verification
  end
end
