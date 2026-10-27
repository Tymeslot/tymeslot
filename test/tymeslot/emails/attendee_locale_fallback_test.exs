defmodule Tymeslot.Emails.AttendeeLocaleFallbackTest do
  @moduledoc """
  Booking mail to an attendee whose language is unknown falls back to the
  booking pages' locale, which an operator can set, rather than to English.
  """

  # async: false: the booking pages' fallback locale is global configuration.
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :i18n

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Templates.AppointmentCancellation

  setup do
    with_config(:tymeslot, :booking_default_locale, "de")
    :ok
  end

  describe "RecipientLocale.attendee_locale/1" do
    test "keeps a supported attendee locale" do
      assert RecipientLocale.attendee_locale(%{attendee_locale: "fr"}) == "fr"
    end

    test "falls back to the booking pages' locale when it is unknown" do
      assert RecipientLocale.attendee_locale(%{attendee_locale: nil}) == "de"
      assert RecipientLocale.attendee_locale(%{}) == "de"
    end

    test "falls back to the booking pages' locale for an unsupported code" do
      assert RecipientLocale.attendee_locale(%{attendee_locale: "xx"}) == "de"
    end
  end

  test "a cancellation to an attendee of unknown language is in the booking pages' language" do
    details = build_appointment_details(%{attendee_locale: nil})
    email = AppointmentCancellation.render(:attendee, "a@b.com", details)

    assert email.subject =~ "Termin abgesagt"
  end
end
