defmodule CredoChecks.GettextDomainBoundary do
  @moduledoc """
  Flags bare `gettext/1,2` and `ngettext/3,4` calls and `dgettext`/`dngettext`
  calls that target an unknown domain.

  Every translatable string must declare *where in the app it lives* through an
  explicit gettext domain. Bare `gettext("...")` silently targets the implicit
  `default` domain, which turns that catalog into an unstructured catch-all —
  exactly what this project's domain-per-area split is designed to avoid. Always
  reach for `dgettext/3` (or `dngettext/4` for plurals) with one of the known
  domains.

  ## Known domains

  Catalogs are split small and per-context. The authoritative table lives in the
  `tymeslot-translations` skill; the `:domains` param below is the enforced copy.

  Public / attendee-facing:

  - `booking` — public booking/scheduling flow (themes)
  - `embed` — the embed-unavailable notice page
  - `emails` — email subjects and bodies
  - `errors` — validation and system error messages
  - `common` — genuinely cross-cutting atoms reused across areas

  Authenticated app — one small domain per feature area:

  - `auth` — login, register, password reset, email verification
  - `account` — account security page (email, password)
  - `onboarding` — post-setup dashboard tour + announcement chrome (frozen)
  - `onboarding_wizard` — the first-run setup wizard
  - `dashboard_common` — sidebar/nav labels and reused button atoms
  - `dashboard_home`, `dashboard_meeting_types`, `dashboard_meeting_form`,
    `dashboard_availability`, `dashboard_calendar_settings`, `dashboard_calendar`,
    `dashboard_calendar_events`, `dashboard_integrations`,
    `dashboard_calendar_providers`, `dashboard_automation`,
    `dashboard_automation_chat`, `dashboard_appearance`, `dashboard_embed`,
    `dashboard_payments`, `dashboard_bookings`, `dashboard_profile`,
    `dashboard_analytics`, `dashboard_admin` — dashboard feature areas

  The former monolithic `dashboard` domain has been resharded into
  `dashboard_admin` (the bulk) and the per-feature domains above.

  Configure the allowlist with the `:domains` param.

  ## Excluded files

  - Files under `/test/` — test support and assertions
  - `gettext.ex` — the backend definition itself
  - Files under `/deps/`

  ## Examples

      # Bad — implicit default domain
      gettext("Confirm your booking")
      ngettext("1 slot", "%{count} slots", count)

      # Bad — unknown domain (typo / not in the taxonomy)
      dgettext("dashboard", "Users")

      # Good — explicit, known domain
      dgettext("booking", "Confirm your booking")
      dngettext("booking", "1 slot", "%{count} slots", count)
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      domains: ~w(
        booking embed emails errors common
        auth account onboarding onboarding_wizard
        dashboard_common
        dashboard_home dashboard_meeting_types dashboard_meeting_form
        dashboard_availability dashboard_calendar_settings dashboard_calendar
        dashboard_calendar_events dashboard_integrations dashboard_calendar_providers
        dashboard_automation dashboard_automation_chat dashboard_appearance
        dashboard_embed dashboard_payments dashboard_bookings dashboard_profile
        dashboard_analytics dashboard_admin
      )
    ],
    explanations: [
      check: """
      Translatable strings must declare their app area through an explicit
      gettext domain. Replace bare `gettext`/`ngettext` with `dgettext`/`dngettext`
      and a known domain, and fix any domain that is not in the allowlist.
      """,
      params: [
        domains: "List of allowed gettext domains."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @bare_calls [:gettext, :ngettext]
  @domained_calls [:dgettext, :dngettext]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if excluded?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      domains = MapSet.new(Params.get(params, :domains, __MODULE__))
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, domains))
    end
  end

  # Bare gettext/ngettext — implicit default domain.
  defp traverse({call, meta, args} = ast, issues, issue_meta, _domains)
       when call in @bare_calls and is_list(args) and args != [] do
    issue =
      format_issue(issue_meta,
        message:
          "`#{call}` targets the implicit `default` domain. Use " <>
            "`d#{call}/#{length(args) + 1}` with an explicit domain instead.",
        line_no: meta[:line],
        trigger: Atom.to_string(call)
      )

    {ast, [issue | issues]}
  end

  # dgettext/dngettext with a string-literal domain — validate against allowlist.
  defp traverse({call, meta, [domain | _rest]} = ast, issues, issue_meta, domains)
       when call in @domained_calls and is_binary(domain) do
    if MapSet.member?(domains, domain) do
      {ast, issues}
    else
      issue =
        format_issue(issue_meta,
          message:
            "Unknown gettext domain #{inspect(domain)}. Allowed domains: " <>
              (domains |> Enum.sort() |> Enum.join(", ")) <> ".",
          line_no: meta[:line],
          trigger: domain
        )

      {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _issue_meta, _domains), do: {ast, issues}

  defp excluded?(filename) do
    Path.basename(filename) == "gettext.ex" or
      String.contains?(filename, "/test/") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/deps/")
  end
end
