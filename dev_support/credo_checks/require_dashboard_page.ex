defmodule CredoChecks.RequireDashboardPage do
  @moduledoc """
  Ensures that main dashboard page components render inside `<.dashboard_page>`.

  Page components under `lib/tymeslot_web/live/dashboard/` share one page
  shell: one root rhythm and one header carrying the page's only `<h1>`, named
  like the section's sidebar entry. The same applies to the
  dashboard pages a downstream overlay contributes from its own web namespace,
  since they render inside the same dashboard shell.

  This is not a "top level only" rule. Page components nested one level down
  (`locations/`, `polls/`) are checked too. Only the helpers listed in
  `@helper_paths` are exempt, because the page component that renders them
  supplies the page shell on their behalf.

  ## Limitations

  It is a text match, deliberately cheap, so it is only as precise as that:

    * Only files ending in `_component.ex` are checked. A page rendered by a
      LiveView of its own (Analytics) or by a `ComponentView` module is not;
      the `ComponentView` delegators are listed in `@helper_paths` and their
      views are trusted to carry the shell.
    * Exemptions are path substrings, so a new file under an exempt
      directory is exempt too, page or not.
    * `#` comments, `@moduledoc`/`@doc` heredocs and HEEx comments are
      stripped before matching, but a `<.dashboard_page` inside any other
      string still counts, and nothing checks that the call is the page's
      root or that it renders.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    exit_status: 0,
    explanations: [
      check: """
      Dashboard page components should render inside `<.dashboard_page>`, so every
      section has the same root and exactly one `<h1>`.
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    if dashboard_page_component?(filename) do
      content = SourceFile.source(source_file)

      if has_dashboard_page?(content) do
        []
      else
        issue_meta = IssueMeta.for(source_file, params)

        [
          format_issue(issue_meta,
            message: "Dashboard page components should render inside `<.dashboard_page>`.",
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

  # Helper components rendered inside a page component, which carries the page
  # shell on their behalf (the integrations hub's tab panels, the automation
  # forms and the theme customiser among them), plus the page components whose
  # `render/1` delegates to a `ComponentView` that carries it. Every entry below matches a
  # directory or file that exists; prune it when one is removed, rather than
  # leaving a pattern that silently matches nothing.
  @helper_paths [
    "/automation/",
    "/availability/",
    "/calendar_grid/",
    "/calendar_settings/",
    "/meeting_settings/",
    "/profile_settings/",
    "/shared/",
    "/subscription/",
    "/theme_customization/",
    "calendar_grid_component",
    "calendar_settings_component",
    "dashboard_overview_component",
    "payments_settings_component",
    "service_settings_component",
    "theme_customization_component",
    "video_settings_component"
  ]

  defp dashboard_page_component?(filename) do
    String.contains?(filename, @dashboard_dirs) and
      String.ends_with?(filename, "_component.ex") and
      not String.contains?(filename, @helper_paths)
  end

  defp has_dashboard_page?(content) do
    content
    |> strip_commentary()
    |> String.contains?(["<.dashboard_page", "<Page.dashboard_page"])
  end

  # Mentions in documentation and comments are not calls.
  defp strip_commentary(content) do
    content
    |> String.replace(~r/@(?:module)?doc\s+~?[sS]?"""[\s\S]*?"""/, "")
    |> String.replace(~r/<%!--[\s\S]*?--%>/, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end
end
