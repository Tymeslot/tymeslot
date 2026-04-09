defmodule Tymeslot.Emails.Templates.AdminAlert do
  @moduledoc """
  Administrative alert email template.

  Renders a single, unified template for every alert type registered in
  `Tymeslot.Infrastructure.AdminAlerts.AlertTypes`. The alert's severity is
  translated into an alert-box colour, and any enriched metadata is rendered
  as a key/value table so self-hosters and operators can copy the report
  verbatim into an issue tracker.
  """

  alias Tymeslot.Emails.Shared.{Components, TemplateHelper}

  @severity_to_alert_type %{
    info: "info",
    warning: "warning",
    error: "error"
  }

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
    alert_type = Map.get(@severity_to_alert_type, severity, "warning")

    mjml_content = """
    #{Components.alert_box(alert_type, message, title: "#{category} alert")}

    <mj-section background-color="#ffffff" border-radius="8px" padding="20px">
      <mj-column>
        #{Components.title_section("Context")}

        #{metadata_table(metadata)}

        #{Components.divider()}

        #{Components.system_footer_note("This is an automated alert from Tymeslot. If you are self-hosting and would like to help debug this issue, you can share the report above (redacting any sensitive values) via a GitHub issue at https://github.com/Tymeslot/tymeslot/issues.")}
      </mj-column>
    </mj-section>
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Tymeslot Admin Alert",
      "#{category}: #{message}"
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

  # --- Metadata rendering ---------------------------------------------------

  defp metadata_table(metadata) when map_size(metadata) == 0 do
    """
    <mj-text font-size="14px" color="#71717a">
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
    <mj-text font-size="14px" color="#3f3f46" line-height="1.6">
      <table role="presentation" width="100%" cellpadding="4" cellspacing="0" style="border-collapse: collapse;">
        #{rows}
      </table>
    </mj-text>
    """
  end

  defp metadata_row({key, value}) do
    """
    <tr>
      <td style="vertical-align: top; padding: 4px 12px 4px 0; color: #71717a; font-weight: 600; white-space: nowrap;">#{html_escape(to_string(key))}</td>
      <td style="vertical-align: top; padding: 4px 0; color: #3f3f46; word-break: break-word;"><code style="font-size: 13px;">#{html_escape(format_value(value))}</code></td>
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

  defp html_escape(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
