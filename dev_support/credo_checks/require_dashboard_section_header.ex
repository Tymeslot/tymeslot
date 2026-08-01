defmodule CredoChecks.RequireDashboardSectionHeader do
  @moduledoc """
  Ensures that main dashboard page components use `<.section_header>` for consistent UI.

  Page components under `lib/tymeslot_web/live/dashboard/` should provide a
  consistent heading using the shared component. The same applies to the
  dashboard pages a downstream overlay contributes from its own web namespace,
  since they render inside the same dashboard shell.

  This is not a "top level only" rule. Page components nested one level down
  (`profile_settings/`, `automation/`, `theme_settings/`) are checked too. Only
  the helper directories listed in `@helper_paths` are exempt, because the page
  component that renders them supplies the heading on their behalf.
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

  # Both web namespaces: the overlay contributes its own dashboard pages through
  # Core's :dashboard_action_components extension point, and they render in the
  # same shell, so the same heading rule applies to them.
  @dashboard_dirs [
    "lib/tymeslot_web/live/dashboard/",
    "lib/tymeslot_saas_web/live/dashboard/"
  ]

  # Helper components rendered inside a page component, which carries the
  # section header on their behalf. Every entry below matches a directory that
  # exists; prune it when one is removed, rather than leaving a pattern that
  # silently matches nothing.
  @helper_paths [
    "/availability/",
    "/calendar_grid/",
    "/calendar_settings/",
    "/meeting_settings/",
    "/shared/",
    "/subscription/",
    "/theme_customization/",
    "calendar_grid_component"
  ]

  defp dashboard_page_component?(filename) do
    String.contains?(filename, @dashboard_dirs) and
      String.ends_with?(filename, "_component.ex") and
      not String.contains?(filename, @helper_paths)
  end

  defp has_section_header?(content) do
    # Check for various ways the component might be called
    String.contains?(content, "<.section_header") or
      String.contains?(content, "<CoreComponents.section_header")
  end
end
