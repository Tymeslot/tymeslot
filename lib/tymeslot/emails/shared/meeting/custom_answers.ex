defmodule Tymeslot.Emails.Shared.Meeting.CustomAnswers do
  @moduledoc """
  Snapshotted custom-field answers for appointment emails. Renders the
  organiser-facing "Additional details" table from the field definitions and
  the booker's answers captured at booking time.
  """

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Emails.Shared.{Sanitise, Styles}

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders a table of snapshotted custom-field answers for display in
  appointment emails. A field whose answer renders empty (left blank, or
  a note the booker did not tick) gets no row, as in the text email and on
  the dashboard; returns an empty string when no row is left.

  `appointment_details` must carry `:custom_fields_snapshot` (list of field
  definition maps) and `:custom_field_answers` (string-keyed map of answers).
  """
  @spec custom_answers_section(map()) :: String.t()
  def custom_answers_section(appointment_details) do
    rows = AnswerRenderer.labelled_answers(appointment_details)

    if rows == [] do
      ""
    else
      row_html =
        Enum.map_join(rows, "\n", fn {label, rendered} ->
          label = Sanitise.sanitize_for_email(label)
          value = Sanitise.sanitize_for_email(rendered)

          """
          <tr style="#{Styles.table_row_style()}">
            <td style="#{Styles.table_label_style()}">#{label}</td>
            <td style="#{Styles.table_value_style()}">#{value}</td>
          </tr>
          """
        end)

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
            #{dgettext("emails", "Additional details")}
          </mj-text>
          <mj-table #{Styles.table_attributes()} css-class="responsive-table">
            #{row_html}
          </mj-table>
        </mj-column>
      </mj-section>
      """
    end
  end
end
