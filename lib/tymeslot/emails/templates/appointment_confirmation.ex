defmodule Tymeslot.Emails.Templates.AppointmentConfirmation do
  @moduledoc """
  Email template for appointment confirmations sent to attendees and organisers.
  Role-dispatched via `render/3`.
  """

  import Swoosh.Email

  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Locales
  alias Tymeslot.MeetingPayments

  alias Tymeslot.Emails.Shared.{
    Callouts,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  require Logger

  use Gettext, backend: TymeslotWeb.Gettext

  # A confirmation email announces a positive outcome — the booking is set.
  @intent :confirmed

  @spec render(
          :attendee | :organizer,
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) :: Swoosh.Email.t()
  def render(:attendee, attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_video_url = Map.get(appointment_details, :attendee_video_url)

      meeting_details = %{
        date: appointment_details.date,
        start_time: appointment_details.start_time_attendee_tz,
        duration: appointment_details.duration,
        location: appointment_details.location,
        location_type: Map.get(appointment_details, :location_type),
        meeting_type: appointment_details.meeting_type,
        video_url: attendee_video_url,
        video_url_role: "attendee"
      }

      intro_copy =
        dgettext(
          "emails",
          "Hi %{name} — I've blocked the time on my calendar and I'm looking forward to our meeting.",
          name: appointment_details.attendee_name
        )

      payment_receipt = build_payment_receipt(appointment_details)

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if attendee_video_url do
        MeetingComponents.video_meeting_section(@intent, attendee_video_url,
        title: dgettext("emails", "Ready to join when it's time?"),
        button_text: dgettext("emails", "Join Video Meeting"))
      end}

      #{if payment_receipt, do: payment_receipt_block_html(payment_receipt)}

      #{Text.section_title(dgettext("emails", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}

      #{if appointment_details.organizer_contact_info do
        Text.centered_text(dgettext("emails", "Questions? %{contact_info}", contact_info: appointment_details.organizer_contact_info), font_size: "14px", padding: "16px 0 0 0")
      end}

      #{if appointment_details.reminders_summary do
        Callouts.alert_box(@intent, appointment_details.reminders_summary, title: dgettext("emails", "Reminders Scheduled"))
      end}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Confirmed"),
          stage_title: dgettext("emails", "You're booked."),
          stage_subtitle:
            dgettext("emails", "Meeting with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Appointment Confirmed - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_attendee_text_body(appointment_details, locale, payment_receipt))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          appointment_details,
          locale,
          "appointment-#{appointment_details.uid}.ics"
        )
      )
    end)
  end

  def render(:organizer, organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      organiser_payment = build_organizer_payment(appointment_details)

      mjml_content = """
      #{MeetingComponents.attendee_info_section(@intent, %{name: appointment_details.attendee_name, email: appointment_details.attendee_email})}

      #{MeetingComponents.attendee_message_box(@intent, appointment_details[:attendee_message])}

      #{MeetingComponents.meeting_details_table(%{date: appointment_details.date, start_time: appointment_details.start_time_owner_tz, duration: appointment_details.duration, location: appointment_details.location, location_type: Map.get(appointment_details, :location_type), meeting_type: appointment_details.meeting_type, video_url: Map.get(appointment_details, :meeting_url), video_url_role: "host"}, organizer_locale(appointment_details))}

      #{MeetingComponents.custom_answers_section(appointment_details)}
      #{if organiser_payment, do: organizer_payment_block_html(organiser_payment)}

      #{Text.section_title(dgettext("emails", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "New booking"),
          stage_title: dgettext("emails", "New Appointment Booked!"),
          stage_subtitle:
            dgettext("emails", "%{name} has scheduled a meeting with you.",
              name: appointment_details.attendee_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      # No ICS attachment for the organiser email. The organiser is the
      # calendar owner — Tymeslot already writes the event straight to their
      # CalDAV/OAuth calendar. An iTIP `METHOD:REQUEST` attachment on top of
      # that causes iMIP-aware mail servers (Zimbra, Exchange, iCloud Mail)
      # to auto-import the ICS as if it were an external invitation,
      # producing a duplicate event and re-sending invites to the attendee.
      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "New Appointment: %{name} - %{date}",
            name: appointment_details.attendee_name,
            date:
              Formatting.format_date_short(
                appointment_details.date,
                organizer_locale(appointment_details)
              )
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_organizer_text_body(appointment_details, organiser_payment))
    end)
  end

  defp build_attendee_text_body(appointment_details, locale, payment_receipt) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(
        Map.get(appointment_details, :attendee_video_url),
        locale
      )

    action_links = TextBodyHelper.format_action_links(appointment_details, locale)
    custom_answers = TextBodyHelper.format_custom_answers(appointment_details, locale)

    payment_section =
      case payment_receipt do
        nil -> ""
        receipt -> "\n#{payment_receipt_block_text(receipt)}\n"
      end

    """
    #{dgettext("emails", "Appointment Confirmed!")}

    #{dgettext("emails", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails", "I'm looking forward to our meeting. I've blocked the time on my calendar and will be ready for you.")}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}
    #{action_links}#{payment_section}
    #{if appointment_details.organizer_contact_info, do: "\n#{dgettext("emails", "QUESTIONS?")}\n#{appointment_details.organizer_contact_info}\n"}
    #{if appointment_details.reminders_summary, do: "\n#{appointment_details.reminders_summary}\n", else: ""}

    #{dgettext("emails", "Looking forward to meeting you!")}
    #{appointment_details.organizer_name}
    """
  end

  defp build_organizer_text_body(appointment_details, organiser_payment) do
    meeting_details =
      TextBodyHelper.format_meeting_details(
        appointment_details,
        organizer_locale(appointment_details)
      )

    attendee_info =
      TextBodyHelper.format_attendee_info(
        appointment_details,
        organizer_locale(appointment_details)
      )

    video_section =
      TextBodyHelper.format_video_section(
        Map.get(appointment_details, :meeting_url),
        organizer_locale(appointment_details)
      )

    action_links =
      TextBodyHelper.format_action_links(
        appointment_details,
        organizer_locale(appointment_details)
      )

    custom_answers =
      TextBodyHelper.format_custom_answers(
        appointment_details,
        organizer_locale(appointment_details)
      )

    payment_section =
      case organiser_payment do
        nil -> ""
        payment -> "\n#{organizer_payment_block_text(payment)}\n"
      end

    """
    #{dgettext("emails", "New Appointment Booked!")}

    #{dgettext("emails", "%{name} has scheduled a meeting with you.", name: appointment_details.attendee_name)}#{attendee_info}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}#{action_links}#{payment_section}

    #{dgettext("emails", "PREPARATION REMINDERS:")}
    #{dgettext("emails", "- Review any relevant materials")}
    #{dgettext("emails", "- Prepare an agenda if needed")}
    #{dgettext("emails", "- Test video/audio setup if virtual")}
    #{organizer_reminder_line(appointment_details)}

    #{dgettext("emails", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp organizer_reminder_line(appointment_details) do
    if Map.get(appointment_details, :reminders_enabled) != false do
      reminder_time = format_reminder_for_organizer(appointment_details)
      dgettext("emails", "- Set a reminder %{time} before", time: reminder_time)
    else
      dgettext("emails", "- No reminder emails are scheduled for this appointment")
    end
  end

  # Format reminder time in organizer's locale, avoiding pre-localized attendee strings
  defp format_reminder_for_organizer(appointment_details) do
    case Map.get(appointment_details, :reminder_raw) do
      %{value: value, unit: unit} ->
        Formatting.format_duration(
          reminder_to_minutes(value, unit),
          organizer_locale(appointment_details)
        )

      _other ->
        dgettext("emails", "15 minutes")
    end
  end

  defp reminder_to_minutes(value, "hours"), do: value * 60
  defp reminder_to_minutes(value, "days"), do: value * 60 * 24
  defp reminder_to_minutes(value, _unit), do: value

  defp organizer_locale(_appointment_details), do: Locales.default_locale()

  # Organiser-facing payment summary. Host emails are intentionally English-only
  # to match the spec; the block shows the gross amount, the platform fee, and
  # the net the host will receive (before Stripe processing fees, which are
  # billed against the host's Stripe balance separately).
  defp build_organizer_payment(appointment_details) do
    case Map.get(appointment_details, :booking_payment) do
      nil ->
        nil

      %{status: status, amount_cents: amount, currency: currency} = bp
      when status in ["paid", "partially_refunded", "refunded"] and is_integer(amount) ->
        application_fee = Map.get(bp, :application_fee_cents) || 0
        net = max(amount - application_fee, 0)

        %{
          attendee_paid: Formatting.format_currency(amount, currency),
          platform_fee: Formatting.format_currency(application_fee, currency),
          net_received: Formatting.format_currency(net, currency)
        }

      _other ->
        nil
    end
  end

  defp organizer_payment_block_html(payment) do
    """
    #{Text.section_title("You received #{Sanitise.sanitize_for_email(payment.net_received)}")}
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="#{Styles.card_radius()}"
      padding="20px 26px"
      css-class="mobile-card email-canvas-soft"
    >
      <mj-column>
        <mj-text
          font-size="15px"
          color="#{Styles.text_color(:primary)}"
          line-height="1.7"
          align="left"
        >
          Attendee paid: <strong>#{Sanitise.sanitize_for_email(payment.attendee_paid)}</strong><br/>
          Tymeslot platform fee: <strong>#{Sanitise.sanitize_for_email(payment.platform_fee)}</strong><br/>
          You received: <strong>#{Sanitise.sanitize_for_email(payment.net_received)}</strong> (less Stripe processing fees)
        </mj-text>
        <mj-text
          font-size="13px"
          color="#{Styles.text_color(:muted)}"
          line-height="1.55"
          align="left"
          padding-top="12px"
        >
          Funds will arrive on your usual Stripe payout schedule.
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp organizer_payment_block_text(payment) do
    String.trim_trailing("""
    PAYMENT RECEIVED:
    You received #{payment.net_received}
    Attendee paid:           #{payment.attendee_paid}
    Tymeslot platform fee:   #{payment.platform_fee}
    You received:            #{payment.net_received} (less Stripe processing fees)

    Funds will arrive on your usual Stripe payout schedule.
    """)
  end

  # Build the attendee-facing payment receipt block from a booking_payment
  # snapshot embedded in `appointment_details`. Returns nil when the
  # booking is free (no booking_payment present) or the payment is not in a
  # paid-like state, so callers can short-circuit.
  defp build_payment_receipt(appointment_details) do
    case Map.get(appointment_details, :booking_payment) do
      nil ->
        nil

      %{status: status, amount_cents: amount, currency: currency} = bp
      when status in ["paid", "partially_refunded", "refunded"] and is_integer(amount) ->
        %{
          amount: Formatting.format_currency(amount, currency),
          paid_at: format_paid_at(bp, appointment_details),
          reference: Map.get(bp, :stripe_charge_id),
          receipt_url: receipt_url_for(bp)
        }

      _other ->
        nil
    end
  end

  defp format_paid_at(%{paid_at: %DateTime{} = paid_at}, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")
    date = Formatting.format_date(DateTime.to_date(paid_at), locale)
    time = Formatting.format_time(paid_at)
    dgettext("emails", "%{date} at %{time}", date: date, time: time)
  end

  defp format_paid_at(_bp, _appointment_details), do: nil

  defp receipt_url_for(%{stripe_charge_id: charge_id, stripe_account_id: account_id})
       when is_binary(charge_id) and charge_id != "" and is_binary(account_id) and
              account_id != "" do
    case MeetingPayments.retrieve_charge_receipt_url(charge_id, account_id) do
      {:ok, url} ->
        url

      {:error, reason} ->
        Logger.warning("Failed to fetch Stripe receipt URL for confirmation email",
          charge_id: charge_id,
          reason: inspect(reason)
        )

        nil
    end
  end

  defp receipt_url_for(_bp), do: nil

  defp payment_receipt_block_html(receipt) do
    title = dgettext("emails", "Payment receipt")

    amount_line =
      dgettext("emails", "%{amount} paid", amount: Sanitise.sanitize_for_email(receipt.amount))

    date_line =
      if receipt.paid_at do
        dgettext("emails", "Date: %{date}", date: Sanitise.sanitize_for_email(receipt.paid_at))
      end

    reference_line =
      if receipt.reference do
        dgettext("emails", "Reference: %{ref}",
          ref: Sanitise.sanitize_for_email(receipt.reference)
        )
      end

    receipt_button =
      if receipt.receipt_url do
        button_label = dgettext("emails", "View receipt")
        safe_url = Sanitise.sanitize_for_email(receipt.receipt_url)

        """
        <mj-button
          href="#{safe_url}"
          background-color="#{Styles.intent_accent_deep(:confirmed)}"
          color="#ffffff"
          border-radius="#{Styles.button_radius()}"
          font-weight="600"
          padding="14px 0 0 0"
          inner-padding="#{Styles.button_padding(:small)}"
        >
          #{button_label}
        </mj-button>
        """
      end

    body_lines =
      [amount_line, date_line, reference_line]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("<br/>\n")

    """
    #{Text.section_title(title)}
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="#{Styles.card_radius()}"
      padding="20px 26px"
      css-class="mobile-card email-canvas-soft"
    >
      <mj-column>
        <mj-text
          font-size="15px"
          color="#{Styles.text_color(:primary)}"
          line-height="1.7"
          align="center"
        >
          #{body_lines}
        </mj-text>
        #{receipt_button}
      </mj-column>
    </mj-section>
    """
  end

  defp payment_receipt_block_text(receipt) do
    header = dgettext("emails", "PAYMENT RECEIPT:")

    amount_line = dgettext("emails", "%{amount} paid", amount: receipt.amount)

    date_line =
      if receipt.paid_at, do: dgettext("emails", "Date: %{date}", date: receipt.paid_at)

    reference_line =
      if receipt.reference, do: dgettext("emails", "Reference: %{ref}", ref: receipt.reference)

    link_line =
      if receipt.receipt_url do
        dgettext("emails", "View receipt: %{url}", url: receipt.receipt_url)
      end

    [header, amount_line, date_line, reference_line, link_line]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
