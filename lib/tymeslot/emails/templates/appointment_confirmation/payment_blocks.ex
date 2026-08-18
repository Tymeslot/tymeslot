defmodule Tymeslot.Emails.Templates.AppointmentConfirmation.PaymentBlocks do
  @moduledoc """
  Payment blocks for the appointment confirmation email.

  A paid booking adds two very different money sections to the confirmation
  email, and neither belongs to the meeting narrative the template otherwise
  tells:

  - the **attendee receipt** — what the booker paid, when, the charge
    reference, and a link to the Stripe-hosted receipt. Rendered in the
    booker's locale.
  - the **organiser summary** — gross, platform fee, and net payout. Rendered
    in the instance's default locale: `AppointmentConfirmation.organizer_locale/1`
    returns it unconditionally rather than reading anything off the organiser.

  Both are built from the `:booking_payment` snapshot embedded in
  `appointment_details`, and both builders return `nil` for a free booking or a
  payment that never reached a paid-like state, so the template can
  short-circuit on one value rather than re-deriving the condition per block.

  This is also the only part of the confirmation email that performs I/O:
  `attendee_receipt/1` calls Stripe to resolve the hosted receipt URL. Keeping
  that here leaves the template itself a pure rendering module.

  Internal to `Tymeslot.Emails.Templates.AppointmentConfirmation`; nothing else
  should call it.
  """

  alias Tymeslot.Emails.Shared.{Formatting, Sanitise, Styles, Text}
  alias Tymeslot.MeetingPayments

  require Logger

  use Gettext, backend: TymeslotWeb.Gettext

  # Payment states that are settled enough to show the booker a receipt and the
  # host a payout summary. A refunded payment still gets both: the money did
  # change hands, and the refund is announced by its own email.
  @paid_like ["paid", "partially_refunded", "refunded"]

  @typedoc "Attendee-facing receipt, or `nil` when there is nothing to show."
  @type receipt ::
          %{
            amount: String.t(),
            paid_at: String.t() | nil,
            reference: String.t() | nil,
            receipt_url: String.t() | nil
          }
          | nil

  @typedoc "Organiser-facing payout summary, or `nil` when there is none."
  @type organizer_summary ::
          %{
            attendee_paid: String.t(),
            platform_fee: String.t(),
            net_received: String.t()
          }
          | nil

  @doc """
  Builds the attendee-facing payment receipt from the `:booking_payment`
  snapshot in `appointment_details`.

  Returns `nil` when the booking is free or the payment is not in a paid-like
  state. Resolves the Stripe-hosted receipt URL, so this performs a network
  call for payments that carry a charge and a connected account.
  """
  @spec attendee_receipt(map()) :: receipt()
  def attendee_receipt(appointment_details) do
    case Map.get(appointment_details, :booking_payment) do
      %{status: status, amount_cents: amount, currency: currency} = bp
      when status in @paid_like and is_integer(amount) ->
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

  @doc """
  Builds the organiser-facing payout summary from the `:booking_payment`
  snapshot in `appointment_details`.

  Shows the gross amount, the platform fee, and the net the host will receive
  (before Stripe processing fees, which are billed against the host's Stripe
  balance separately). Returns `nil` when the booking is free or the payment is
  not in a paid-like state.
  """
  @spec organizer_summary(map()) :: organizer_summary()
  def organizer_summary(appointment_details) do
    case Map.get(appointment_details, :booking_payment) do
      %{status: status, amount_cents: amount, currency: currency} = bp
      when status in @paid_like and is_integer(amount) ->
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

  @doc "Renders the attendee receipt as MJML."
  @spec attendee_receipt_html(map()) :: String.t()
  def attendee_receipt_html(receipt) do
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
        #{receipt_button(receipt)}
      </mj-column>
    </mj-section>
    """
  end

  @doc "Renders the attendee receipt as plain text."
  @spec attendee_receipt_text(map()) :: String.t()
  def attendee_receipt_text(receipt) do
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

  @doc "Renders the organiser payout summary as MJML."
  @spec organizer_summary_html(map()) :: String.t()
  def organizer_summary_html(payment) do
    # `Text.section_title/2` escapes what it is handed, so the amount goes in raw.
    title = dgettext("emails", "You received %{amount}", amount: payment.net_received)

    body_lines =
      Enum.join(
        [
          dgettext("emails", "Attendee paid: %{amount}", amount: strong(payment.attendee_paid)),
          dgettext("emails", "Tymeslot platform fee: %{amount}",
            amount: strong(payment.platform_fee)
          ),
          dgettext("emails", "You received: %{amount} (less Stripe processing fees)",
            amount: strong(payment.net_received)
          )
        ],
        "<br/>\n"
      )

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
          align="left"
        >
          #{body_lines}
        </mj-text>
        <mj-text
          font-size="13px"
          color="#{Styles.text_color(:muted)}"
          line-height="1.55"
          align="left"
          padding-top="12px"
        >
          #{dgettext("emails", "Funds will arrive on your usual Stripe payout schedule.")}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "Renders the organiser payout summary as plain text."
  @spec organizer_summary_text(map()) :: String.t()
  # The label column used to be padded to a fixed width; that is gone on
  # purpose, because a translated label is a different length and the padding
  # would misalign in every locale but English.
  def organizer_summary_text(payment) do
    [
      dgettext("emails", "PAYMENT RECEIVED:"),
      dgettext("emails", "You received %{amount}", amount: payment.net_received),
      dgettext("emails", "Attendee paid: %{amount}", amount: payment.attendee_paid),
      dgettext("emails", "Tymeslot platform fee: %{amount}", amount: payment.platform_fee),
      dgettext("emails", "You received: %{amount} (less Stripe processing fees)",
        amount: payment.net_received
      ),
      "",
      dgettext("emails", "Funds will arrive on your usual Stripe payout schedule.")
    ]
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  # The bold markup rides in on the placeholder rather than living inside the
  # msgid, so the HTML and plain-text summaries share one translation each.
  defp strong(amount), do: "<strong>#{Sanitise.sanitize_for_email(amount)}</strong>"

  defp receipt_button(%{receipt_url: nil}), do: nil

  defp receipt_button(%{receipt_url: receipt_url}) do
    button_label = dgettext("emails", "View receipt")
    safe_url = Sanitise.sanitize_for_email(receipt_url)
    accent_deep = Styles.intent_accent_deep(:confirmed)

    """
    <mj-button
      href="#{safe_url}"
      background-color="#{accent_deep}"
      color="#{Styles.button_text_color(accent_deep)}"
      border-radius="#{Styles.button_radius()}"
      font-weight="600"
      padding="14px 0 0 0"
      inner-padding="#{Styles.button_padding(:small)}"
    >
      #{button_label}
    </mj-button>
    """
  end

  defp format_paid_at(%{paid_at: %DateTime{} = paid_at}, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")
    Formatting.format_datetime(paid_at, locale)
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
end
