defmodule Tymeslot.Emails.Templates.AdminAlertDigest do
  @moduledoc """
  The daily digest of info-severity admin alerts.

  Renders the payload `Tymeslot.Infrastructure.AdminAlerts.Digest` hands to the
  email worker, with string keys as the job stores them:

    * `"entries"`: one map per distinct alert, with `"alert_type"`,
      `"category"`, `"message"`, `"occurrences"`, `"first_seen_at"`,
      `"last_seen_at"` and the scrubbed `"metadata"`
    * `"omitted"`: alert type to occurrence count, for alerts beyond the
      per-email cap
    * `"deployment"`: the instance's deployment context
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles, TemplateHelper, Text}

  @doc """
  The digest's subject, carrying the severity like every admin alert and the
  number of alerts it reports, repeats and omitted ones included.
  """
  @spec subject(map()) :: String.t()
  def subject(digest) do
    "[INFO] Tymeslot: daily digest (#{pluralise(total_alerts(digest), "alert")})"
  end

  @doc """
  Renders the HTML body.
  """
  @spec render(map()) :: String.t()
  def render(digest) do
    entries = Map.get(digest, "entries", [])

    mjml_content = """
    #{Text.title_section("#{pluralise(total_alerts(digest), "info alert")} since the last digest")}

    #{Enum.map_join(entries, "\n", &entry_html/1)}

    #{omitted_html(Map.get(digest, "omitted", %{}))}

    #{Text.divider()}

    #{context_html(Map.get(digest, "deployment", %{}))}

    #{Text.system_footer_note("This is an automated daily digest from Tymeslot. Warnings and errors are emailed as they happen; informational alerts are collected here.")}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Tymeslot Admin Alert Digest",
      subject(digest),
      intent: :confirmed,
      eyebrow: "Admin",
      stage_title: "Daily alert digest",
      stage_subtitle: pluralise(length(entries), "distinct alert")
    )
  end

  @doc """
  Renders the plain-text body.
  """
  @spec render_text(map()) :: String.t()
  def render_text(digest) do
    """
    TYMESLOT ADMIN ALERT DIGEST

    #{pluralise(total_alerts(digest), "info alert")} since the last digest.

    #{Enum.map_join(Map.get(digest, "entries", []), "\n", &entry_text/1)}
    #{omitted_text(Map.get(digest, "omitted", %{}))}
    DEPLOYMENT
    #{pairs_text(Map.get(digest, "deployment", %{}))}

    ---
    This is an automated daily digest from Tymeslot. Warnings and errors are
    emailed as they happen; informational alerts are collected here.
    """
  end

  # --- Entries --------------------------------------------------------------

  defp entry_html(entry) do
    """
    <mj-section padding="0 0 12px 0">
      <mj-column>
        <mj-text font-size="15px" color="#{Styles.ink()}" line-height="1.5" padding="0 0 4px 0">
          <strong>#{escape(entry["message"])}</strong>
        </mj-text>
        <mj-text font-size="13px" color="#{Styles.ink_muted()}" line-height="1.5" padding="0">
          #{escape(summary_line(entry))}#{metadata_html(Map.get(entry, "metadata", %{}))}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp metadata_html(metadata) when map_size(metadata) == 0, do: ""

  defp metadata_html(metadata) do
    "<br/><code style=\"font-size: 12px;\">#{escape(pairs_inline(metadata))}</code>"
  end

  defp entry_text(entry) do
    metadata = Map.get(entry, "metadata", %{})

    context =
      if map_size(metadata) == 0, do: "", else: "\n  #{pairs_inline(metadata)}"

    "* #{entry["message"]}\n  #{summary_line(entry)}#{context}\n"
  end

  defp summary_line(entry) do
    "#{entry["category"]} / #{entry["alert_type"]}: " <>
      "#{pluralise(entry["occurrences"], "time")}, first #{entry["first_seen_at"]}, " <>
      "last #{entry["last_seen_at"]}"
  end

  # --- Omitted --------------------------------------------------------------

  defp omitted_html(omitted) when map_size(omitted) == 0, do: ""

  defp omitted_html(omitted) do
    """
    #{Text.section_title("Not listed: over the per-email limit")}
    #{Text.bullet_list(omitted_lines(omitted))}
    """
  end

  defp omitted_text(omitted) when map_size(omitted) == 0, do: ""

  defp omitted_text(omitted) do
    lines = Enum.map_join(omitted_lines(omitted), "\n", &"  #{&1}")
    "\nNOT LISTED: OVER THE PER-EMAIL LIMIT\n#{lines}\n"
  end

  defp omitted_lines(omitted) do
    omitted
    |> Enum.sort()
    |> Enum.map(fn {type, count} -> "#{type}: #{pluralise(count, "alert")}" end)
  end

  # --- Deployment context ---------------------------------------------------

  defp context_html(context) when map_size(context) == 0, do: ""

  defp context_html(context) do
    """
    <mj-section padding="0">
      <mj-column>
        <mj-text font-size="13px" color="#{Styles.ink_muted()}" line-height="1.6" padding="0">
          #{escape(pairs_inline(context))}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  # --- Helpers ----------------------------------------------------------------

  defp total_alerts(digest) do
    listed = digest |> Map.get("entries", []) |> Enum.map(&(&1["occurrences"] || 1)) |> Enum.sum()
    omitted = digest |> Map.get("omitted", %{}) |> Map.values() |> Enum.sum()
    listed + omitted
  end

  defp pairs_inline(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{format_value(value)}" end)
  end

  defp pairs_text(map) when map_size(map) == 0, do: "  (none)"

  defp pairs_text(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> "  #{key}: #{format_value(value)}" end)
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp format_value(value), do: inspect(value)

  defp escape(value), do: Sanitise.sanitize_for_email(to_string(value))

  defp pluralise(1, noun), do: "1 #{noun}"
  defp pluralise(count, noun), do: "#{count} #{noun}s"
end
