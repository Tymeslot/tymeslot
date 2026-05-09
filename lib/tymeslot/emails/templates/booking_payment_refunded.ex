defmodule Tymeslot.Emails.Templates.BookingPaymentRefunded do
  @moduledoc """
  Attendee email confirming that a booking payment has been refunded — fully
  or partially. Built from a normalised `RefundContext` struct so raw Stripe
  payloads never reach the template layer.

  Triggered synchronously by `Tymeslot.MeetingPayments.Refunds.issue_refund/3`
  via the dedicated `Tymeslot.Workers.SendBookingPaymentRefunded` worker.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text
  }

  alias Tymeslot.Locales

  use Gettext, backend: TymeslotWeb.Gettext

  # A refund is a remedial event — use the cancelled intent palette so
  # the surface palette matches the user's mental model.
  @intent :cancelled

  defmodule RefundContext do
    @moduledoc """
    Normalised data passed to the refund email template.

    Building this struct in the worker keeps the template free of any
    knowledge of database schemas or Stripe payloads.
    """

    @enforce_keys [
      :attendee_email,
      :attendee_name,
      :host_name,
      :meeting_title,
      :amount_cents,
      :refunded_amount_cents,
      :currency,
      :is_full_refund?,
      :locale
    ]
    defstruct [
      :attendee_email,
      :attendee_name,
      :host_name,
      :meeting_title,
      :amount_cents,
      :refunded_amount_cents,
      :currency,
      :is_full_refund?,
      :locale
    ]

    @type t :: %__MODULE__{
            attendee_email: String.t(),
            attendee_name: String.t() | nil,
            host_name: String.t() | nil,
            meeting_title: String.t() | nil,
            amount_cents: pos_integer(),
            refunded_amount_cents: pos_integer(),
            currency: String.t(),
            is_full_refund?: boolean(),
            locale: String.t()
          }
  end

  @spec render(RefundContext.t()) :: Swoosh.Email.t()
  def render(%RefundContext{} = context) do
    locale = context.locale || Locales.default_locale()

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_name = context.attendee_name || dgettext("emails", "there")
      host_name = context.host_name || dgettext("emails", "your host")

      refunded_amount =
        Formatting.format_currency(context.refunded_amount_cents, context.currency)

      original_amount = Formatting.format_currency(context.amount_cents, context.currency)

      intro_copy =
        if context.is_full_refund? do
          dgettext(
            "emails",
            "Hi %{name} — your payment of %{amount} has been refunded in full.",
            name: attendee_name,
            amount: refunded_amount
          )
        else
          dgettext(
            "emails",
            "Hi %{name} — %{amount} of your %{original} payment has been refunded.",
            name: attendee_name,
            amount: refunded_amount,
            original: original_amount
          )
        end

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{refund_details_card(context, refunded_amount, original_amount)}

      #{Text.system_footer_note(dgettext("emails", "Refunds typically take 5–10 business days to appear on your original payment method, depending on your bank."))}
      #{Text.system_footer_note(dgettext("emails", "If you have any questions, please reply to this email and %{name} will be happy to help.", name: host_name))}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(
          %{
            organizer_name: host_name,
            organizer_email: nil,
            organizer_title: nil,
            organizer_avatar_url: nil
          },
          intent: @intent,
          eyebrow: dgettext("emails", "Refunded"),
          stage_title:
            if(context.is_full_refund?,
              do: dgettext("emails", "Your payment was refunded."),
              else: dgettext("emails", "A partial refund was issued.")
            ),
          stage_subtitle: refund_subtitle(context, refunded_amount)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({attendee_name, context.attendee_email})
      |> subject(
        if context.is_full_refund? do
          dgettext("emails", "Refund Issued - %{amount}", amount: refunded_amount)
        else
          dgettext("emails", "Partial Refund Issued - %{amount}", amount: refunded_amount)
        end
      )
      |> html_body(html_body)
      |> text_body(text_body(context, refunded_amount, original_amount, attendee_name, host_name))
    end)
  end

  defp refund_subtitle(%RefundContext{meeting_title: title}, refunded_amount)
       when is_binary(title) and title != "" do
    dgettext("emails", "%{amount} returned for “%{title}”", amount: refunded_amount, title: title)
  end

  defp refund_subtitle(_context, refunded_amount) do
    dgettext("emails", "%{amount} returned to your card", amount: refunded_amount)
  end

  defp refund_details_card(context, refunded_amount, original_amount) do
    label = Sanitise.sanitize_for_email(dgettext("emails", "Refund details"))

    refund_line =
      Sanitise.sanitize_for_email(
        dgettext("emails", "Refunded amount: %{amount}", amount: refunded_amount)
      )

    original_line =
      Sanitise.sanitize_for_email(
        dgettext("emails", "Original payment: %{amount}", amount: original_amount)
      )

    meeting_line =
      if context.meeting_title do
        Sanitise.sanitize_for_email(
          dgettext("emails", "Meeting: %{title}", title: context.meeting_title)
        )
      end

    body_lines =
      [refund_line, original_line, meeting_line]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("<br/>\n")

    """
    #{Text.section_title(label)}
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
      </mj-column>
    </mj-section>
    """
  end

  defp text_body(context, refunded_amount, original_amount, attendee_name, host_name) do
    intro =
      if context.is_full_refund? do
        dgettext(
          "emails",
          "Hi %{name}, your payment of %{amount} has been refunded in full.",
          name: attendee_name,
          amount: refunded_amount
        )
      else
        dgettext(
          "emails",
          "Hi %{name}, %{amount} of your %{original} payment has been refunded.",
          name: attendee_name,
          amount: refunded_amount,
          original: original_amount
        )
      end

    title_line =
      if context.meeting_title,
        do: dgettext("emails", "Meeting: %{title}", title: context.meeting_title)

    [
      dgettext("emails", "REFUND ISSUED"),
      "",
      intro,
      "",
      dgettext("emails", "REFUND DETAILS:"),
      dgettext("emails", "Refunded amount: %{amount}", amount: refunded_amount),
      dgettext("emails", "Original payment: %{amount}", amount: original_amount),
      title_line,
      "",
      dgettext(
        "emails",
        "Refunds typically take 5–10 business days to appear on your original payment method, depending on your bank."
      ),
      "",
      dgettext(
        "emails",
        "If you have any questions, please reply to this email and %{name} will be happy to help.",
        name: host_name
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
