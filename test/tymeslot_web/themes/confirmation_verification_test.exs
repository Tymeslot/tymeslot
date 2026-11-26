defmodule TymeslotWeb.Themes.ConfirmationVerificationTest do
  @moduledoc """
  The confirmation step for a booking waiting for its attendee to confirm
  their email address: every shipped theme asks them to check their inbox,
  names where the link went and how long the time is held, and offers
  nothing that belongs to a booking (no calendar file, no hints to
  reschedule or withdraw), even on a type that also needs the host's
  approval, whose request is only made once the address is confirmed. Also
  the shared pieces: `ConfirmationText`'s decision and the resend control.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :themes

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Shared.Components.VerificationNotice
  alias TymeslotWeb.Themes.Shared.ConfirmationText
  alias TymeslotWeb.ThemeTestMatrix

  @help_copy [
    "Check your confirmation email",
    "Check your email for reschedule options",
    "Your request email has a link to withdraw it"
  ]

  describe "ConfirmationText.status/1" do
    test "a booking awaiting verification is checked before approval" do
      assert ConfirmationText.status(%{
               meeting_status: :awaiting_verification,
               meeting_type: build(:meeting_type, requires_approval: true)
             }) == :check_inbox
    end

    test "owner preview never asks to check the inbox" do
      assigns = %{owner_preview: true, meeting_status: :awaiting_verification}

      assert ConfirmationText.status(assigns) == :confirmed
      assert ConfirmationText.follow_ups?(assigns)
    end

    test "only a booking awaiting verification drops the follow-ups" do
      refute ConfirmationText.follow_ups?(%{meeting_status: :awaiting_verification})
      assert ConfirmationText.follow_ups?(%{meeting_status: :awaiting_approval})
      assert ConfirmationText.follow_ups?(%{meeting_status: :confirmed})
    end
  end

  describe "ConfirmationText.badge_icon/1 and pending?/1" do
    test "an envelope while the inbox is checked, a clock while held, a tick once confirmed" do
      waiting = verification_assigns()
      held = %{waiting | meeting_status: :awaiting_approval}
      confirmed = %{waiting | meeting_status: :confirmed}

      assert {ConfirmationText.badge_icon(waiting), ConfirmationText.pending?(waiting)} ==
               {"hero-envelope", true}

      assert {ConfirmationText.badge_icon(held), ConfirmationText.pending?(held)} ==
               {"hero-clock", true}

      assert {ConfirmationText.badge_icon(confirmed), ConfirmationText.pending?(confirmed)} ==
               {"hero-check", false}
    end
  end

  describe "ConfirmationText.check_inbox_message/2" do
    test "states the deadline as a time in the attendee's timezone" do
      message =
        ConfirmationText.check_inbox_message(%{
          email: "ana@example.com",
          verification_deadline_at: ~U[2026-09-10 09:30:00Z],
          user_timezone: "Europe/Ljubljana"
        })

      assert message =~ "Click it by 10 September 2026 at 11:30 AM CEST"
      refute message =~ "minutes"
    end

    # Without its date, a hold running past midnight on the attendee's clock
    # would read as a time already gone.
    test "a deadline past the attendee's midnight names its own date" do
      message =
        ConfirmationText.check_inbox_message(%{
          email: "ana@example.com",
          verification_deadline_at: ~U[2026-09-10 22:10:00Z],
          user_timezone: "Europe/Ljubljana"
        })

      assert message =~ "Click it by 11 September 2026 at 12:10 AM CEST"
    end

    # The hold is capped at the meeting's start, so a booking made ten minutes
    # before it is held for ten minutes, not thirty.
    test "a booking made 10 minutes before its start shows the start-capped time" do
      start_time = ~U[2026-09-10 10:00:00Z]

      %{verification_deadline_at: deadline} =
        EmailVerification.gate_attributes(~U[2026-09-10 09:50:00Z], start_time)

      message =
        ConfirmationText.check_inbox_message(%{
          email: "ana@example.com",
          verification_deadline_at: deadline,
          user_timezone: "UTC"
        })

      assert message =~ "Click it by 10 September 2026 at 10:00 AM UTC"
      refute message =~ "10:20"
    end

    test "a one-to-one booking holds the time" do
      message = ConfirmationText.check_inbox_message(verification_assigns())

      assert message =~ "Until then the time is held for you."
      refute message =~ "place"
    end

    # Other attendees may share the slot's time, so what is held is the
    # booker's place, as the seat's verification email says.
    test "a seat on a group meeting holds the booker's place, not the time" do
      message = ConfirmationText.check_inbox_message(seat_assigns())

      assert message =~ "Click it by 10 September 2026 at 09:30 AM UTC"
      assert message =~ "Until then your place is held for you."
      refute message =~ "the time is held"
    end
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}" do
      test "every theme shows check your inbox for a booking awaiting verification" do
        html = render_theme(unquote(theme.id), verification_assigns())

        assert [message] = find(html, "[data-testid='check-inbox']")
        assert Floki.text(message) =~ "ana@example.com"
        assert Floki.text(message) =~ "Click it by 10 September 2026 at 09:30 AM UTC"

        assert Floki.text(find(html, "[data-testid='confirmation-heading']")) =~
                 "Check your inbox"

        assert find(html, "[data-testid='resend-verification']") != []

        assert find(html, "[data-testid='add-to-calendar']") == []
        assert Enum.reject(@help_copy, &(html =~ &1)) == @help_copy

        # Nothing is confirmed yet: the badge takes its pending look, and
        # the address line does not call the email a confirmation.
        assert html =~ "badge--pending"
        refute html =~ "Confirmation sent to"
      end

      # The page never holds the uid of a booking awaiting verification; were
      # it ever handed one, the step still offers no calendar file.
      test "a seat on a group meeting says its place is held" do
        html = render_theme(unquote(theme.id), seat_assigns())

        assert [message] = find(html, "[data-testid='check-inbox']")
        assert Floki.text(message) =~ "Until then your place is held for you."
        refute Floki.text(message) =~ "the time is held"
      end

      test "offers no calendar file even if a uid were known" do
        html =
          render_theme(unquote(theme.id), %{verification_assigns() | meeting_uid: "abc123"})

        assert find(html, "[data-testid='add-to-calendar']") == []
        refute html =~ "abc123"
      end

      test "a gated approval booking is not shown as a request yet" do
        type = build(:meeting_type, requires_email_verification: true, requires_approval: true)
        html = render_theme(unquote(theme.id), %{verification_assigns() | meeting_type: type})

        assert find(html, "[data-testid='approval-notice']") == []
        assert find(html, "[data-testid='check-inbox']") != []
        refute html =~ "Request sent"
        refute html =~ "your request"
      end

      test "a confirmed booking keeps its calendar file and has no check-inbox copy" do
        html =
          render_theme(unquote(theme.id), %{
            verification_assigns()
            | meeting_status: :confirmed,
              meeting_uid: "abc123"
          })

        assert find(html, "[data-testid='add-to-calendar']") != []
        assert find(html, "[data-testid='check-inbox']") == []
        assert find(html, "[data-testid='resend-verification']") == []
        refute html =~ "badge--pending"
        # Anchors the check-inbox case's refute: the help copy it expects
        # gone is what every theme shows a confirmed booking.
        assert Enum.any?(@help_copy, &(html =~ &1))
      end
    end
  end

  describe "VerificationNotice.line/1" do
    test "says a link will follow, only for a type that requires verification" do
      gated = render_component(&VerificationNotice.line/1, meeting_type: gated_type())
      assert gated =~ ~s(data-testid="verification-notice")
      assert gated =~ "email you a link to confirm this booking"

      ungated = render_component(&VerificationNotice.line/1, meeting_type: build(:meeting_type))
      refute ungated =~ "verification-notice"
    end
  end

  describe "VerificationNotice.resend/1" do
    test "offers the button before any press, with no status" do
      html = render_resend(nil)

      assert [button] = find(html, "[data-testid='resend-verification']")
      assert Floki.attribute(button, "phx-click") == ["resend_verification_email"]
      assert Floki.attribute(button, "disabled") == []
      assert find(html, "[data-testid='resend-verification-status']") == []
    end

    test "disables the button after a resend and says it went" do
      html = render_resend(:sent)

      assert [button] = find(html, "[data-testid='resend-verification']")
      assert Floki.attribute(button, "disabled") != []
      assert status(html) =~ "Sent again"
    end

    test "keeps the button when the press can be tried again" do
      for {state, text} <- [retry: "Please try again", rate_limited: "Too many attempts"] do
        html = render_resend(state)

        assert find(html, "[data-testid='resend-verification']") != [], "#{state}"
        assert status(html) =~ text
      end
    end

    test "keeps the button while the slot awaits a new time" do
      html = render_resend(:awaiting_new_time)

      assert find(html, "[data-testid='resend-verification']") != []
      assert status(html) =~ "The organiser is changing this meeting's time"
      assert status(html) =~ "You can try again while your place is held."
    end

    test "hides the button once nothing more can be sent" do
      for {state, text} <- [
            limit_reached: "cannot send the email again",
            expired: "The time was released",
            place_released: "Your place was released because the booking was not confirmed",
            used: "no longer waiting for your confirmation"
          ] do
        html = render_resend(state)

        assert find(html, "[data-testid='resend-verification']") == [], "#{state}"
        assert status(html) =~ text
      end
    end
  end

  defp render_theme(theme_id, assigns) do
    component = ThemeInfo.get_live_view_module(theme_id).__journey__().outcomes.confirmation
    render_component(component, assigns)
  end

  defp render_resend(state), do: render_component(&VerificationNotice.resend/1, state: state)

  defp find(html, selector), do: html |> Floki.parse_fragment!() |> Floki.find(selector)

  defp status(html), do: Floki.text(find(html, "[data-testid='resend-verification-status']"))

  defp gated_type, do: build(:meeting_type, requires_email_verification: true)

  defp seat_assigns do
    %{
      verification_assigns()
      | meeting_type: build(:meeting_type, requires_email_verification: true, max_participants: 3)
    }
  end

  defp verification_assigns do
    %{
      id: "confirmation-step",
      locale: "en",
      duration: "30-minutes",
      username_context: "hostuser",
      selected_date: "2026-09-10",
      selected_time: "10:00",
      user_timezone: "UTC",
      email: "ana@example.com",
      verification_deadline_at: ~U[2026-09-10 09:30:00Z],
      guest_emails: [],
      name: "Ana",
      organizer_profile: build(:profile, full_name: "Jane Organizer"),
      meeting_type: gated_type(),
      meeting_status: :awaiting_verification,
      meeting_uid: nil,
      seat_calendar_url: nil,
      custom_fields_snapshot: [],
      custom_field_answers: %{},
      is_rescheduling: false,
      theme_tokens: %Tokens{},
      journey: nil,
      current_state: :confirmation
    }
  end
end
