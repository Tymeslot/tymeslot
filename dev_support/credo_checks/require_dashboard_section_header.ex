defmodule CredoChecks.RequireDashboardSectionHeader do
  @moduledoc """
  Ensures that main dashboard page components use `<.section_header>` for consistent UI.

  Main components at the top level of `lib/tymeslot_web/live/dashboard/` should
  provide a consistent heading using the shared component.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    exit_status: 0,
    explanations: [
      check: """
      Dashboard page components should use `<.section_header>` for consistent UI.
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    if dashboard_page_component?(filename) do
      content = SourceFile.source(source_file)

      if has_section_header?(content) do
        []
      else
        issue_meta = IssueMeta.for(source_file, params)

        [
          format_issue(issue_meta,
            message:
              "Dashboard page components should use `<.section_header>` for consistent UI.",
            line_no: 1,
            trigger: filename
          )
        ]
      end
    else
      []
    end
  end

  defp dashboard_page_component?(filename) do
    # Target main dashboard components (top-level in the dashboard directory)
    # excluding subdirectories which usually contain helper components
    String.contains?(filename, "apps/tymeslot/lib/tymeslot_web/live/dashboard/") and
      String.ends_with?(filename, "_component.ex") and
      not String.contains?(filename, [
        "/availability/",
        "/calendar_settings/",
        "/meeting_settings/",
        "/meetings/",
        "/shared/",
        "/theme_customization/",
        "/calendar_grid/",
        "calendar_grid_component"
      ])
  end

  defp has_section_header?(content) do
    # Check for various ways the component might be called
    String.contains?(content, "<.section_header") or
      String.contains?(content, "<CoreComponents.section_header")
  end
end
