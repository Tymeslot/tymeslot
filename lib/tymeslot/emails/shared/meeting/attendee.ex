defmodule Tymeslot.Emails.Shared.Meeting.Attendee do
  @moduledoc """
  Attendee blocks for organiser-facing meeting emails — the contact information
  table, the optional attendee-message callout, and, for a meeting nobody
  booked, the list of its guests.

  Both components take an explicit intent so colouring (link, tint, rail)
  matches the surrounding stage band.
  """

  alias Tymeslot.Emails.Shared.Meeting.Notes
  alias Tymeslot.Emails.Shared.{Sanitise, Styles}
  alias Tymeslot.Emails.Shared.Styles.Tokens

  use Gettext, backend: TymeslotWeb.Gettext

  @type attendee_info :: %{
          required(:name) => String.t(),
          required(:email) => String.t(),
          optional(:phone) => String.t() | nil,
          optional(:company) => String.t() | nil,
          optional(:timezone) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Attendee information section — key/value block for organiser emails. The
  caller supplies the email `intent` so the mailto link colour stays
  consistent with the surrounding stage band.
  """
  @spec attendee_info_section(Tokens.intent(), attendee_info()) :: String.t()
  def attendee_info_section(intent, attendee) when is_atom(intent) do
    safe_name = Sanitise.sanitize_for_email(attendee.name)
    safe_email = Sanitise.sanitize_for_email(attendee.email)

    """
    <mj-section padding="8px 0 20px 0">
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          padding="0 0 12px 0"
        >
          #{dgettext("emails", "Attendee Information")}
        </mj-text>
        <mj-table #{Styles.table_attributes()} css-class="responsive-table">
          #{attendee_row(dgettext("emails", "Name"), safe_name)}
          #{attendee_email_row(intent, safe_email)}
          #{attendee_optional_row(dgettext("emails", "Phone"), attendee[:phone])}
          #{attendee_optional_row(dgettext("emails", "Company"), attendee[:company])}
          #{attendee_optional_row(dgettext("emails", "Timezone"), attendee[:timezone])}
        </mj-table>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  Who the organiser's copy is about: the attendee, or, for a meeting the
  host manages (`:host_managed`, see
  `Tymeslot.Emails.AppointmentBuilder.organizer_copy/2`), its guests, since
  nobody booked it.
  """
  @spec counterpart_section(Tokens.intent(), map()) :: String.t()
  def counterpart_section(intent, %{host_managed: true} = details),
    do: guests_section(intent, details.guests)

  def counterpart_section(intent, details),
    do:
      attendee_info_section(intent, %{name: details.attendee_name, email: details.attendee_email})

  defp guests_section(intent, guests) do
    """
    <mj-section padding="8px 0 20px 0">
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          padding="0 0 12px 0"
        >
          #{dgettext("emails", "Guests")}
        </mj-text>
        <mj-table #{Styles.table_attributes()} css-class="responsive-table">
          #{Enum.map_join(guests, "", &guest_row(intent, &1))}
        </mj-table>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A small tinted callout for the attendee's message left during booking. The
  caller supplies the email `intent` so the tint matches the stage band.
  """
  @spec attendee_message_box(Tokens.intent(), String.t() | nil) :: String.t()
  def attendee_message_box(intent, message),
    do: Notes.callout(intent, dgettext("emails", "Message from attendee"), message)

  defp attendee_row(label, value) do
    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">#{label}</td>
      <td style="#{Styles.table_value_style()}">#{value}</td>
    </tr>
    """
  end

  defp attendee_email_row(intent, safe_email),
    do: email_row(intent, dgettext("emails", "Email"), safe_email)

  # A guest who gave a name is listed under it; one who gave none, under
  # "Email", as their address alone.
  defp guest_row(intent, %{name: name, email: email}) when is_binary(name) and name != "",
    do: email_row(intent, Sanitise.sanitize_for_email(name), Sanitise.sanitize_for_email(email))

  defp guest_row(intent, %{email: email}),
    do: attendee_email_row(intent, Sanitise.sanitize_for_email(email))

  defp email_row(intent, label, safe_email) do
    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">#{label}</td>
      <td style="#{Styles.table_value_style()}">
        <a href="mailto:#{safe_email}" style="color: #{Styles.intent_accent_deep(intent)}; font-weight: 600; text-decoration: none;">#{safe_email}</a>
      </td>
    </tr>
    """
  end

  defp attendee_optional_row(_label, nil), do: ""
  defp attendee_optional_row(_label, ""), do: ""

  defp attendee_optional_row(label, value) do
    safe_value = Sanitise.sanitize_for_email(value)
    attendee_row(label, safe_value)
  end
end
