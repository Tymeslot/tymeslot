defmodule Tymeslot.Emails.Templates.MissingActionUrlsTest do
  @moduledoc """
  An action whose URL is missing or unsafe is left out of a booking email
  altogether, in both parts: no button or link pointing nowhere (`href="#"`),
  no "Reschedule: #" line, and no heading over an empty set of actions.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.{
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled
  }

  @unsafe "javascript:alert(1)"

  defp without_links do
    build_appointment_details(%{
      reschedule_url: nil,
      cancel_url: @unsafe,
      guest_accept_url: nil,
      guest_decline_url: @unsafe,
      guest_name: "Greg Guest"
    })
  end

  defp refute_dead_links(email) do
    refute email.html_body =~ ~r/href="(#|\s*)"/
    refute email.html_body =~ "javascript:"
    refute email.text_body =~ ": #"
    refute email.text_body =~ "javascript:"
  end

  for template <- [AppointmentConfirmation, AppointmentReminder, AppointmentRescheduled] do
    describe "#{inspect(template)}" do
      test "the booker gets no reschedule or cancel action without a URL" do
        email = unquote(template).render(:attendee, "attendee@example.com", without_links())

        refute_dead_links(email)
        refute email.html_body =~ "Cancel Appointment"
        refute email.html_body =~ ">Cancel<"
        refute email.text_body =~ "Reschedule:"
        refute email.text_body =~ "Cancel:"
        refute email.text_body =~ "ACTIONS:"
        refute email.text_body =~ "Need to change plans?"
        refute email.text_body =~ "Need to make changes?"
      end

      test "the organiser gets no reschedule or cancel action without a URL" do
        email = unquote(template).render(:organizer, "organizer@example.com", without_links())

        refute_dead_links(email)
        refute email.html_body =~ "Cancel Appointment"
        refute email.html_body =~ ">Cancel<"
        refute email.text_body =~ "Reschedule:"
        refute email.text_body =~ "ACTIONS:"
      end

      test "a guest gets no answer links without a URL" do
        email = unquote(template).render(:guest, "greg@example.com", without_links())

        refute_dead_links(email)
        refute email.html_body =~ "attend"
        refute email.html_body =~ "make it"
        refute email.text_body =~ "attend:"
        refute email.text_body =~ "make it"
      end

      test "a guest with an answer link keeps it, in both parts" do
        details = %{without_links() | guest_accept_url: "https://example.com/yes"}
        email = unquote(template).render(:guest, "greg@example.com", details)

        assert email.html_body =~ ~s(href="https://example.com/yes")
        assert email.text_body =~ "Yes, I'll attend: https://example.com/yes"
        refute email.text_body =~ "Can't make it"
      end
    end
  end

  test "a booker with only a cancel link keeps it, in both parts" do
    details = %{without_links() | cancel_url: "https://example.com/cancel"}
    email = AppointmentConfirmation.render(:attendee, "attendee@example.com", details)

    assert email.html_body =~ ~s(href="https://example.com/cancel")
    assert email.text_body =~ "ACTIONS:\nCancel: https://example.com/cancel"
    refute email.text_body =~ "Reschedule:"
  end
end
