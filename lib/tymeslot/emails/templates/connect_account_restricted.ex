defmodule Tymeslot.Emails.Templates.ConnectAccountRestricted do
  @moduledoc """
  Host-facing email sent when Stripe transitions a Connect account into a
  restricted state — for example, missing capability information, identity
  verification needed, or platform suspension.

  Written in the host's own language.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Cards,
    Greeting,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  defmodule RestrictionContext do
    @moduledoc """
    Normalised data for the account-restricted email. The worker looks up the
    user and Stripe account state once and hands a flat struct to the template;
    `host_user_id` picks the language the email is written in.
    """

    @enforce_keys [:host_email, :disabled_reason]
    defstruct [
      :host_email,
      :host_name,
      :host_user_id,
      :disabled_reason,
      :previous_disabled_reason,
      :charges_enabled,
      :payouts_enabled,
      :dashboard_url
    ]

    @type t :: %__MODULE__{
            host_email: String.t(),
            host_name: String.t() | nil,
            host_user_id: integer() | nil,
            disabled_reason: String.t(),
            previous_disabled_reason: String.t() | nil,
            charges_enabled: boolean() | nil,
            payouts_enabled: boolean() | nil,
            dashboard_url: String.t() | nil
          }
  end

  @doc """
  The restriction alert, in the language of the host identified by
  `host_user_id` (the default locale when there is none).
  """
  @spec render(RestrictionContext.t()) :: Swoosh.Email.t()
  def render(%RestrictionContext{} = context) do
    RecipientLocale.with_user_id_locale(context.host_user_id, fn ->
      host = %{name: context.host_name}
      reason_label = humanise_reason(context.disabled_reason)
      dashboard_url = context.dashboard_url || "https://dashboard.stripe.com/"
      status = status(context, reason_label)

      MjmlEmail.base_email()
      |> to(recipient(context.host_name, context.host_email))
      |> subject(dgettext("emails_payments", "Stripe account restricted: action required"))
      |> header("X-Priority", "1")
      |> html_body(html(host, reason_label, status, dashboard_url))
      |> text_body(text(host, status, dashboard_url))
    end)
  end

  defp html(host, reason_label, status, dashboard_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(host), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(intro(), padding: "0 0 16px 0")}

    #{Cards.details_card(Sanitise.sanitize_for_email(dgettext("emails_payments", "Account status")), status_html(status))}

    #{Text.section_title(dgettext("emails_payments", "Restore your account"))}
    #{Text.centered_text(dgettext("emails_payments", "Open the Stripe dashboard to see exactly what Stripe needs from you and complete any outstanding requirements."), padding: "0 0 14px 0")}
    #{Buttons.action_button(@intent, dgettext("emails_payments", "Open Stripe dashboard"), dashboard_url, full_width: true)}

    #{Text.system_footer_note(resolution())}
    """

    # This is a platform-to-host operational alert, not a message from an
    # organiser — use the system layout so no organiser strip is rendered.
    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_payments", "Stripe account restricted"),
      dgettext(
        "emails_payments",
        "Your Stripe account needs attention to keep taking payments."
      ),
      intent: @intent,
      eyebrow: dgettext("emails_payments", "Action required"),
      stage_title: dgettext("emails_payments", "Your Stripe account is restricted"),
      stage_subtitle: reason_label
    )
  end

  defp text(host, status, dashboard_url) do
    Enum.join(
      [
        dgettext("emails_payments", "STRIPE ACCOUNT RESTRICTED"),
        "",
        Greeting.text(host),
        "",
        intro(),
        "",
        dgettext("emails_payments", "ACCOUNT STATUS:"),
        Enum.map_join(status, "\n", fn {label, value} -> "#{label} #{value}" end),
        "",
        dgettext("emails_payments", "RESTORE YOUR ACCOUNT:"),
        dgettext(
          "emails_payments",
          "Open the Stripe dashboard to see what Stripe needs from you:"
        ),
        dashboard_url,
        "",
        resolution()
      ],
      "\n"
    )
  end

  # Only attach a display name when the host actually has one — otherwise a
  # nil name would surface a placeholder as the recipient's name.
  defp recipient(name, email) when is_binary(name) and name != "", do: {name, email}
  defp recipient(_name, email), do: email

  defp intro,
    do:
      dgettext(
        "emails_payments",
        "Stripe has flagged your connected account as restricted. New paid bookings will continue to work only while charges remain enabled, so please act on this promptly."
      )

  defp resolution,
    do:
      dgettext(
        "emails_payments",
        "Once Stripe is satisfied, your account state updates automatically. Nothing more is needed on Tymeslot's side."
      )

  # The account's state as label and value, the same in both parts; a state
  # Stripe did not report is left out.
  defp status(context, reason_label) do
    rows = [
      {dgettext("emails_payments", "Restriction:"), reason_label},
      {dgettext("emails_payments", "Charges enabled:"), enabled_label(context.charges_enabled)},
      {dgettext("emails_payments", "Payouts enabled:"), enabled_label(context.payouts_enabled)}
    ]

    Enum.reject(rows, fn {_label, value} -> is_nil(value) end)
  end

  # The restriction, first, is the one fact set in bold.
  defp status_html([{label, reason} | rest]) do
    first =
      "#{Sanitise.sanitize_for_email(label)} <strong>#{Sanitise.sanitize_for_email(reason)}</strong>"

    rest_html =
      Enum.map(rest, fn {l, v} ->
        "#{Sanitise.sanitize_for_email(l)} #{Sanitise.sanitize_for_email(v)}"
      end)

    Enum.join([first | rest_html], "<br/>\n")
  end

  defp enabled_label(true), do: dgettext("emails_payments", "yes")
  defp enabled_label(false), do: dgettext("emails_payments", "no")
  defp enabled_label(nil), do: nil

  # Stripe's `disabled_reason` strings are dot-separated machine codes (e.g.
  # "requirements.past_due", "rejected.fraud"). Show them as-is so the host
  # can match the wording against Stripe's own dashboard messages.
  defp humanise_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp humanise_reason(_reason), do: dgettext("emails_payments", "Account restricted")
end
