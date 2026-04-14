defmodule Tymeslot.Emails.Templates.AdminAlert do
  @moduledoc """
  Administrative alert email template.

  Renders a single, unified template for every alert type registered in
  `Tymeslot.Infrastructure.AdminAlerts.AlertTypes`. The alert's severity is
  translated into an alert-box intent, and any enriched metadata is rendered
  as a key/value table so self-hosters and operators can copy the report
  verbatim into an issue tracker.
  """

  alias Tymeslot.Emails.Shared.{Callouts, Sanitise, Styles, TemplateHelper, Text}

  @intent :alert

  @doc """
  Renders the HTML body for an admin alert email.
  """
  @spec render(
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map()
        ) :: String.t()
  def render(category, severity, message, metadata) do
    callout_intent = severity_to_intent(severity)

    mjml_content = """
    #{Callouts.alert_box(callout_intent, message, title: "#{category} alert")}

    #{Text.title_section("Context")}

    #{metadata_table(metadata)}

    #{Text.divider()}

    #{Text.system_footer_note("This is an automated alert from Tymeslot. If you are self-hosting and would like to help debug this issue, you can share the report above (redacting any sensitive values) via a GitHub issue at https://github.com/Tymeslot/tymeslot/issues.")}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Tymeslot Admin Alert",
      "#{category}: #{message}",
      intent: @intent,
      eyebrow: "Admin",
      stage_title: "#{category} alert",
      stage_subtitle: message
    )
  end

  @doc """
  Renders the plain-text body for an admin alert email.
  """
  @spec render_text(
          category :: String.t(),
          severity :: :info | :warning | :error,
          message :: String.t(),
          metadata :: map()
        ) :: String.t()
  def render_text(category, severity, message, metadata) do
    """
    TYMESLOT ADMIN ALERT

    Category: #{category}
    Severity: #{severity}

    #{message}

    CONTEXT
    #{metadata_text(metadata)}

    ---
    This is an automated alert from Tymeslot.
    Self-hosters: to help debug this issue, please share the report above
    (redacting any sensitive values) via https://github.com/Tymeslot/tymeslot/issues.
    """
  end

  # --- Severity mapping -----------------------------------------------------

  @spec severity_to_intent(:info | :warning | :error) :: atom()
  defp severity_to_intent(:info), do: :confirmed
  defp severity_to_intent(:warning), do: :alert
  defp severity_to_intent(:error), do: :cancelled
  defp severity_to_intent(_other), do: :alert

  # --- Metadata rendering ---------------------------------------------------

  defp metadata_table(metadata) when map_size(metadata) == 0 do
    """
    <mj-text font-size="14px" color="#{Styles.ink_muted()}">
      <em>No additional context.</em>
    </mj-text>
    """
  end

  defp metadata_table(metadata) do
    rows =
      metadata
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("\n", &metadata_row/1)

    """
    <mj-text font-size="14px" color="#{Styles.ink()}" line-height="1.6">
      <table role="presentation" width="100%" cellpadding="4" cellspacing="0" style="border-collapse: collapse;">
        #{rows}
      </table>
    </mj-text>
    """
  end

  defp metadata_row({key, value}) do
    """
    <tr>
      <td style="vertical-align: top; padding: 4px 12px 4px 0; color: #{Styles.ink_muted()}; font-weight: 600; white-space: nowrap;">#{Sanitise.sanitize_for_email(to_string(key))}</td>
      <td style="vertical-align: top; padding: 4px 0; color: #{Styles.ink()}; word-break: break-word;"><code style="font-size: 13px;">#{Sanitise.sanitize_for_email(format_value(value))}</code></td>
    </tr>
    """
  end

  defp metadata_text(metadata) when map_size(metadata) == 0, do: "(none)"

  defp metadata_text(metadata) do
    metadata
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join("\n", fn {k, v} -> "  #{k}: #{format_value(v)}" end)
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value), do: inspect(value)
end
